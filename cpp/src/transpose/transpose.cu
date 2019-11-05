/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <cudf/transpose.hpp>
#include <cudf/detail/transpose.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/utilities/nvtx_utils.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/detail/copy.hpp>
#include <utilities/integer_utils.hpp>

namespace cudf {

namespace {

constexpr int WARP_SIZE = 32;
constexpr int MAX_GRID_SIZE = (1<<16)-1;

/**
 * @brief Transposes the values from ncols x nrows input to nrows x ncols output 
 * 
 * @tparam T  Datatype of values pointed to by the views
 * @param input[in]  Device view of input columns' data
 * @param output[out]  Mutable device view of pre-allocated output columns' data
 */
template <typename T>
__global__
void gpu_transpose(table_device_view const input, mutable_table_device_view output)
{
  size_type x = blockIdx.x * blockDim.x + threadIdx.x;
  size_type y = blockIdx.y * blockDim.y + threadIdx.y;

  size_type stride_x = blockDim.x * gridDim.x;
  size_type stride_y = blockDim.y * gridDim.y;

  for (size_type i = x; i < input.num_columns(); i += stride_x) {
    for (size_type j = y; j < input.num_rows(); j += stride_y) {
      output.column(j).element<T>(i) = input.column(i).element<T>(j);
    }
  }
}

/**
 * @brief Transposes the null mask from ncols x nrows input to nrows x ncols output
 * 
 * @tparam T  Datatype of values pointed to by the views
 * @param input[in]  Device view of input columns' data
 * @param output[out]  Mutable device view of pre-allocated output columns' data
 */
__global__
void gpu_transpose_valids(table_device_view const input, mutable_table_device_view output,
                          size_type *null_count)
{
  size_type x = blockIdx.x * blockDim.x + threadIdx.x;
  size_type y = blockIdx.y * blockDim.y + threadIdx.y;

  size_type stride_x = blockDim.x * gridDim.x;
  size_type stride_y = blockDim.y * gridDim.y;

  size_type i = x;
  auto active_threads = __ballot_sync(0xffffffff, i < input.num_columns());
  while (i < input.num_columns()) {
    for (size_type j = y; j < input.num_rows(); j += stride_y) {
      auto const result = __ballot_sync(active_threads, input.column(i).is_valid(j));

      // Only one thread writes output
      if (0 == threadIdx.x % WARP_SIZE) {
        output.column(j).set_mask_word(word_index(i), result);
        int num_nulls = __popc(active_threads) - __popc(result);
        atomicAdd(null_count + j, num_nulls);
      }
    }

    // Update active threads before branching
    i += stride_x;
    active_threads = __ballot_sync(active_threads, i < input.num_columns());
  }
}

struct launch_kernel {
  template <typename T>
  void operator()(
    table_view const& input,
    mutable_table_view& output,
    std::vector<size_type>& null_counts,
    cudaStream_t stream)
  {
    // Copy input columns `data` and `valid` pointers to device
    auto device_input = table_device_view::create(input, stream);
    auto device_output = mutable_table_device_view::create(output, stream);

    // TODO benchmark, because a smaller block size (e.g. 32x8) may perform
    // better. It would also require transposing via shared memory, which may
    // improve performance anyway because it would enable coalesced loads and
    // stores rather than one or the other.
    dim3 dimBlock(WARP_SIZE, WARP_SIZE);
    dim3 dimGrid(std::min(util::div_rounding_up_safe(input.num_columns(), WARP_SIZE), MAX_GRID_SIZE),
                 std::min(util::div_rounding_up_safe(input.num_rows(), WARP_SIZE), MAX_GRID_SIZE));

    gpu_transpose<T><<<dimGrid, dimBlock, 0, stream>>>(*device_input, *device_output);

    if (not null_counts.empty()) {
      rmm::device_vector<cudf::size_type> d_null_counts(null_counts.size());
      gpu_transpose_valids<<<dimGrid, dimBlock, 0, stream>>>(*device_input,
        *device_output, d_null_counts.data().get());

      // This memcpy needs to be synchronous as we immediately read the value from host
      CUDA_TRY(cudaMemcpyAsync(null_counts.data(), d_null_counts.data().get(),
        null_counts.size() * sizeof(size_type), cudaMemcpyDefault, stream));
      CUDA_TRY(cudaStreamSynchronize(stream));
    }
  }
};

}  // namespace

namespace detail {

std::unique_ptr<experimental::table> transpose(table_view const& input,
  rmm::mr::device_memory_resource* mr, cudaStream_t stream)
{
  auto const input_ncols = input.num_columns();
  auto const input_nrows = input.num_rows();

  // If there are no rows in the input, return successfully
  if (input_ncols == 0 || input_nrows == 0) {
    return std::make_unique<experimental::table>();
  }

  // Check datatype homogeneity
  auto const& first = input.column(0);
  auto const dtype = first.type();
  CUDF_EXPECTS(std::all_of(input.begin(), input.end(), [dtype](auto const& col) {
    return dtype == col.type(); }), "Column type mismatch");

  // TODO string support may be needed in future
  CUDF_EXPECTS(is_fixed_width(dtype), "Invalid, non-fixed-width type.");


  // Check if there are nulls to be processed
  bool const has_null = has_nulls(input);
  auto const allocation_policy = has_null ? experimental::mask_allocation_policy::ALWAYS
    : experimental::mask_allocation_policy::NEVER;

  auto const& output_ncols = input_nrows;
  auto const& output_nrows = input_ncols;
  std::vector<size_type> null_counts(has_null ? output_ncols : 0);

  // Allocate output table with transposed shape
  std::vector<std::unique_ptr<column>> out_columns(output_ncols);
  std::generate(out_columns.begin(), out_columns.end(), [=]() {
    return experimental::detail::allocate_like(first, output_nrows,
      allocation_policy, mr, stream);
  });
  auto output = std::make_unique<experimental::table>(std::move(out_columns));
  auto output_view = output->mutable_view();

  nvtx::range_push("CUDF_TRANSPOSE", nvtx::color::GREEN);
  experimental::type_dispatcher(dtype, launch_kernel{}, input, output_view, null_counts, stream);
  nvtx::range_pop();

  if (has_null) {
    for (size_type i = 0; i < output_ncols; ++i) {
      output->get_column(i).set_null_count(null_counts[i]);
    }
  }

  return output;
}

}  // namespace detail

std::unique_ptr<experimental::table> transpose(table_view const& input,
                                 rmm::mr::device_memory_resource* mr)
{
  return detail::transpose(input, mr);
}

}  // namespace cudf
