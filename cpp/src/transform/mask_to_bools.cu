/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <thrust/iterator/constant_iterator.h>
#include <thrust/transform.h>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/transform.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/bit.hpp>

namespace cudf {
namespace detail {
std::unique_ptr<column> mask_to_bools(bitmask_type const* bitmask,
                                      size_type offset,
                                      size_type length,
                                      cudaStream_t stream,
                                      rmm::mr::device_memory_resource* mr)
{
  if (length == 0)
    return make_fixed_width_column(
      data_type(type_id::BOOL8), 0, mask_state::UNALLOCATED, stream, mr);

  CUDF_EXPECTS((bitmask != nullptr), "nullmask is null");

  auto out_col =
    make_fixed_width_column(data_type(type_id::BOOL8), length, mask_state::UNALLOCATED, stream, mr);

  auto mutable_view = out_col->mutable_view();

  thrust::transform(
    rmm::exec_policy(stream)->on(stream),
    thrust::make_counting_iterator<cudf::size_type>(0),
    thrust::make_counting_iterator<cudf::size_type>(mutable_view.size()),
    mutable_view.begin<bool>(),
    [bitmask, offset] __device__(auto index) { return bit_is_set(bitmask, offset + index); });

  return std::move(out_col);
}
}  // namespace detail

std::unique_ptr<column> mask_to_bools(bitmask_type const* bitmask,
                                      size_type offset,
                                      size_type length,
                                      rmm::mr::device_memory_resource* mr)
{
  return detail::mask_to_bools(bitmask, offset, length, 0, mr);
}
}  // namespace cudf
