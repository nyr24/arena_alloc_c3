module arena_alloc;

// Individual allocation structure: [size=8bytes|payload|padding]

import std::math;
import std::collections::list;

const usz MIN_REGION_SIZE = 1024u;

struct ArenaRegion
{
	char[] data;
	uint   cursor;
}

struct ArenaSnapshot
{
	uint region;
	uint cursor;
}

struct ArenaAlloc
{
	List{ArenaRegion} 	regions;
	Allocator			backing_alloc;
	AllocInitType		alloc_init_type;
	uint 				last_region_ind;
	uint				snapshot_count;
}

fn void ArenaAlloc.init(&arena, Allocator backing_alloc, usz init_region_count, usz init_first_region_size = 0, AllocInitType alloc_init_type = AllocInitType.NO_ZERO)
{
	arena.backing_alloc = backing_alloc;
	arena.last_region_ind = 0;
	arena.alloc_init_type = alloc_init_type;
	arena.regions.init(backing_alloc, init_region_count);

	if (init_first_region_size != 0) {
		arena.push_region(init_first_region_size);
	}
}

<*
 Acquire memory from the allocator, with the given alignment and initialization type.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require size > 0 : "The size must be 1 or more"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.acquire(&arena, usz size, AllocInitType init_type, usz alignment = 0)
{
	alignment = allocator::alignment_for_allocation(alignment);
	usz aligned_size_with_header = mem::aligned_offset(size + allocator::DEFAULT_SIZE_PREFIX, alignment);
	usz aligned_size = aligned_size_with_header - allocator::DEFAULT_SIZE_PREFIX;
	ArenaRegion* region = null;
	uint reg_ind = arena.snapshot_count > 0 ? arena.last_region_ind : 0;

	for (; reg_ind < arena.regions.size; ++reg_ind) {
		ArenaRegion* curr = &arena.regions[reg_ind];
		if (aligned_size <= (curr.data.len - curr.cursor)) {
			region = curr;
			break;
		}
	}

	if (!region) {
		arena.push_region(aligned_size_with_header);
		reg_ind = (uint)(arena.regions.size - 1);
		region = &arena.regions[reg_ind];
	}

	return arena.finalize_alloc(region, aligned_size, reg_ind);
}

<*
 Resize acquired memory from the allocator, with the given new size and alignment.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require ptr != null
 @require new_size > 0
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.resize(&arena, void* ptr, usz new_size, usz alignment = 0)
{
	alignment = allocator::alignment_for_allocation(alignment);
	usz aligned_new_size_with_header = mem::aligned_offset(new_size + allocator::DEFAULT_SIZE_PREFIX, alignment);
	usz aligned_new_size = aligned_new_size_with_header - allocator::DEFAULT_SIZE_PREFIX;
	ArenaRegion* reg = null;
	uint reg_ind = 0;
	
	foreach (uint i, &curr_reg : arena.regions) {
		if (curr_reg.owns_ptr(ptr)) {
			reg = curr_reg;
			reg_ind = i;
			break;
		}
	}

	if (!reg) {
		return null;
	}

	usz* old_size = (usz*)(ptr - allocator::DEFAULT_SIZE_PREFIX);
	isz alloc_size_diff = aligned_new_size - *old_size;
	
	// if allocation was last one in this region
	if ALLOCATE_NEW: (reg.is_last_alloc(ptr, *old_size)) {
		bool alloc_fits_curr_reg = (alloc_size_diff < 0) ? true : (reg.cursor + alloc_size_diff) <= reg.data.len;
		if (!alloc_fits_curr_reg) {
			break ALLOCATE_NEW;
		}
		*old_size = aligned_new_size;
		reg.cursor += (uint)alloc_size_diff;
		return ptr;
	}

	// if allocation was NOT last one in this region
	bool enough_place_at_end = aligned_new_size_with_header <= (reg.data.len - reg.cursor);
	if (enough_place_at_end) {
		return arena.finalize_alloc(reg, aligned_new_size, reg_ind);
	}

	// allocate new region for this allocation
	arena.push_region(aligned_new_size_with_header);
	reg = &arena.regions[arena.regions.size - 1];
	return arena.finalize_alloc(reg, aligned_new_size, (uint)(arena.regions.size - 1));
}

<*
 Release memory acquired using `acquire` or `resize`.

 @require ptr != null : "Empty pointers should never be released"
*>
fn void ArenaAlloc.release(&arena, void* ptr, bool aligned)
{
	ArenaRegion* reg = null;
	
	foreach (&curr_reg : arena.regions) {
		if (curr_reg.owns_ptr(ptr)) {
			reg = curr_reg;
			break;
		}
	}

	if (!reg) {
		return;
	}

	usz* alloc_size = (usz*)(ptr - allocator::DEFAULT_SIZE_PREFIX);
	if (!reg.is_last_alloc(ptr, *alloc_size)) {
		return;
	}
	reg.cursor -= (uint)(*alloc_size + allocator::DEFAULT_SIZE_PREFIX);
}

fn void ArenaAlloc.ensure_capacity(&arena, usz cap)
{
	usz alignment = mem::DEFAULT_MEM_ALIGNMENT;
	usz aligned_cap_with_header = mem::aligned_offset(cap + allocator::DEFAULT_SIZE_PREFIX, alignment);
	ArenaRegion* region = null;
	uint reg_ind = arena.snapshot_count > 0 ? arena.last_region_ind : 0;

	for (; reg_ind < arena.regions.size; ++reg_ind) {
		ArenaRegion* curr = &arena.regions[reg_ind];
		if (aligned_cap_with_header <= (curr.data.len - curr.cursor)) {
			region = curr;
			arena.last_region_ind = math::max(arena.last_region_ind, reg_ind);
			return;
		}
	}

	if (!region) {
		arena.push_region(aligned_cap_with_header);
		arena.last_region_ind = (uint)(arena.regions.size - 1);
	}
}

fn ArenaSnapshot ArenaAlloc.create_snapshot(&arena)
{
	ArenaSnapshot snap;
	snap.region = arena.last_region_ind;
	snap.cursor = arena.regions[arena.last_region_ind].cursor;
	arena.snapshot_count++;
	return snap;
}

fn void ArenaAlloc.rewind_snapshot(&arena, ArenaSnapshot* snapshot)
{
	arena.last_region_ind = snapshot.region;
	arena.regions[snapshot.region].cursor = snapshot.cursor; 
	arena.snapshot_count--;
}

fn bool ArenaRegion.is_last_alloc(&reg, void* ptr, usz alloc_size) @inline @local
{
	usz alloc_cursor = (usz)(ptr + alloc_size) - (usz)reg.data.ptr;
	return alloc_cursor == reg.cursor;
}

// inserts allocation after region.cursor
// aligned_size - allocation size without header
fn void* ArenaAlloc.finalize_alloc(&arena, ArenaRegion* reg, usz aligned_size, uint reg_ind) @inline @local
{
	void* ret = reg.data.ptr + reg.cursor + allocator::DEFAULT_SIZE_PREFIX;
	usz* header = (usz*)(ret - allocator::DEFAULT_SIZE_PREFIX);
	*header = aligned_size;
	reg.cursor += (uint)(aligned_size + allocator::DEFAULT_SIZE_PREFIX);
	arena.last_region_ind = math::max(arena.last_region_ind, reg_ind);
	return ret;
}

fn void ArenaAlloc.push_region(&arena, usz size) @inline @local
{
	arena.regions.push(create_region(arena.backing_alloc, size, arena.alloc_init_type));
}

fn ArenaRegion create_region(Allocator backing_alloc, usz size, AllocInitType alloc_init_type = AllocInitType.NO_ZERO) @local
{
	ArenaRegion reg;
	if (alloc_init_type == AllocInitType.ZERO) {
		reg.data = allocator::new_array(backing_alloc, char, math::max(size, MIN_REGION_SIZE));
	} else {
		reg.data = allocator::alloc_array(backing_alloc, char, math::max(size, MIN_REGION_SIZE));
	}
	return reg;
}

fn bool ArenaRegion.owns_ptr(&reg, void* ptr)
{
	return (uptr)ptr >= (uptr)reg.data.ptr && (uptr)ptr < (uptr)reg.data.ptr + reg.data.len;
}
