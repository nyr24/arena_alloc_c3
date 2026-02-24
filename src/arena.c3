module arena;

// Individual allocation structure: [size=8bytes|payload|padding]

import std::math;
import std::collections::list;

const usz DEFAULT_REGION_SIZE = 4096u;
const usz MIN_REGION_SIZE = 1024u;

faultdef PTR_NOT_OWNED;

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

struct ArenaAlloc (Allocator)
{
	List{ArenaRegion} 	regions;
	Allocator			backing_alloc;
	AllocInitType		alloc_init_type;
	uint 				last_region_ind;
	uint				snapshot_count;
	uint				min_region_size;
}

<*
	Initializes the arena.

	@require init_region_capacity >= 1 : "Should be at least one"
	@require min_region_size >= MIN_REGION_SIZE : "Shouldn't be less than this"
	@require first_region_size >= MIN_REGION_SIZE : "Shouldn't be less than this"
*>
fn void ArenaAlloc.init(
	&arena,
	Allocator     backing_alloc,
	uint          min_region_size = DEFAULT_REGION_SIZE,
	uint          first_region_size = DEFAULT_REGION_SIZE,
	usz           init_region_capacity = 1,
	AllocInitType alloc_init_type = NO_ZERO,
)
{
	arena.backing_alloc = backing_alloc;
	arena.alloc_init_type = alloc_init_type;
	arena.min_region_size = min_region_size;
	arena.regions.init(backing_alloc, init_region_capacity);
	arena.push_region(first_region_size);
}

<*
	Acquire memory from the allocator, with the given alignment and initialization type.

	@require !alignment || math::is_power_of_2(alignment)
	@require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
	@require size > 0 : "The size must be 1 or more"
	@return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.acquire(&arena, usz size, AllocInitType init_type, usz alignment = 0) @dynamic
{
	alignment = allocator::alignment_for_allocation(alignment);
	usz aligned_size_with_header = mem::aligned_offset(size + allocator::DEFAULT_SIZE_PREFIX, alignment);
	usz aligned_size = aligned_size_with_header - allocator::DEFAULT_SIZE_PREFIX;
	ArenaRegion* region = null;
	uint reg_ind = arena.snapshot_count > 0 ? arena.last_region_ind : 0;

	for (; reg_ind < arena.regions.size; ++reg_ind) {
		ArenaRegion* curr = &arena.regions[reg_ind];
		if (aligned_size <= curr.remain_mem()) {
			region = curr;
			break;
		}
	}

	if (!region) {
		uint last_ind = arena.push_region(aligned_size_with_header);
		region = &arena.regions[last_ind];
	}

	return finalize_alloc(arena, region, aligned_size, reg_ind);
}

<*
	Resize acquired memory from the allocator, with the given new size and alignment.

	@require !alignment || math::is_power_of_2(alignment)
	@require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
	@require ptr != null
	@require new_size > 0
	@return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY, PTR_NOT_OWNED
*>
fn void*? ArenaAlloc.resize(&arena, void* ptr, usz new_size, usz alignment = 0) @dynamic
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
		return PTR_NOT_OWNED~;
	}

	usz* old_size = (usz*)(ptr - allocator::DEFAULT_SIZE_PREFIX);
	isz alloc_size_diff = aligned_new_size - *old_size;
	bool last_alloc = reg.is_last_alloc(ptr, *old_size);
	
	// if allocation was last one in this region
	if ALLOCATE_NEW: (last_alloc) {
		bool alloc_fits_curr_reg = (alloc_size_diff < 0) ? true : (reg.cursor + alloc_size_diff) <= reg.data.len;
		if (!alloc_fits_curr_reg) {
			// free this alloc and jump
			reg.cursor -= (uint)(*old_size + allocator::DEFAULT_SIZE_PREFIX);
			break ALLOCATE_NEW;
		}
		*old_size = aligned_new_size;
		reg.cursor += (uint)alloc_size_diff;
		return ptr;
	}

	// if allocation was NOT last one in this region try to feet it at the end
	if (!last_alloc) {
		bool enough_place_at_end = aligned_new_size_with_header <= reg.remain_mem();
		if (enough_place_at_end) {
			void* ret = finalize_alloc(arena, reg, aligned_new_size, reg_ind);
			mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
			return ret;
		}
	}

	void*? ret = arena.acquire(aligned_new_size, arena.alloc_init_type, alignment);
	if (catch excuse = ret) {
		return excuse~;
	}
	mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
	return ret;
}

<*
	Release memory acquired using `acquire` or `resize`.

	@require ptr != null : "Empty pointers should never be released"
*>
fn void ArenaAlloc.release(&arena, void* ptr, bool aligned) @dynamic
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

<*
	Ensure that arena has contiguous memory space of size 'cap'

	Use case for this: you know that you will have 'n' small allocations
	and you don't want to preallocate all the space for them in 'acquire' call,
	but made them as separate ones, still preserving opportunity for storing them in a single Region
*>
fn void ArenaAlloc.ensure_capacity(&arena, usz cap)
{
	usz alignment = mem::DEFAULT_MEM_ALIGNMENT;
	usz aligned_cap_with_header = mem::aligned_offset(cap + allocator::DEFAULT_SIZE_PREFIX, alignment);
	ArenaRegion* region = null;
	uint reg_ind = arena.snapshot_count > 0 ? arena.last_region_ind : 0;

	for (; reg_ind < arena.regions.size; ++reg_ind) {
		ArenaRegion* curr = &arena.regions[reg_ind];
		if (aligned_cap_with_header <= curr.remain_mem()) {
			arena.last_region_ind = math::max(arena.last_region_ind, reg_ind);
			return;
		}
	}

	// didn't found sufficient region, acquire new one
	arena.push_region(aligned_cap_with_header);
}

<*
	Create a 'mark' from which you can start doing temporary allocations,
	then easily reclaim them back with 'rewind_snapshot'
*>
fn ArenaSnapshot ArenaAlloc.create_snapshot(&arena)
{
	ArenaSnapshot snap;
	snap.region = arena.last_region_ind;
	snap.cursor = arena.regions[arena.last_region_ind].cursor;
	arena.snapshot_count++;
	return snap;
}

<*
	Reclaim all memory used since a call to 'create_snapshot'
*>
fn void ArenaAlloc.rewind_snapshot(&arena, ArenaSnapshot snapshot)
{
	for (int i = arena.last_region_ind; i > snapshot.region; --i) {
		arena.regions[i].cursor = 0; 
	}
	arena.regions[snapshot.region].cursor = snapshot.cursor; 
	arena.last_region_ind = snapshot.region;
	arena.snapshot_count--;
}

macro ArenaAlloc.@temp_scope(&arena; @body)
{
	ArenaSnapshot sn = arena.create_snapshot();
	defer arena.rewind_snapshot(sn);
	@body();
}

<*
	Inserts allocation after region.cursor
	aligned_size - allocation size without header
*>
fn void* finalize_alloc(ArenaAlloc* arena, ArenaRegion* reg, usz aligned_size, uint reg_ind) @inline @local
{
	void* ret = reg.data.ptr + reg.cursor + allocator::DEFAULT_SIZE_PREFIX;
	usz* header = (usz*)(ret - allocator::DEFAULT_SIZE_PREFIX);
	*header = aligned_size;
	reg.cursor += (uint)(aligned_size + allocator::DEFAULT_SIZE_PREFIX);
	arena.last_region_ind = math::max(arena.last_region_ind, reg_ind);
	return ret;
}

fn uint ArenaAlloc.push_region(&arena, usz size) @inline @local
{
	arena.regions.push(create_region(arena, size));
	arena.last_region_ind = math::max(arena.last_region_ind, (uint)(arena.regions.size - 1));
	return arena.last_region_ind;
}

<*
	Set the size that will be used as 'min' capacity boundary for newly created arena region
*>
fn void ArenaAlloc.set_min_region_size(&arena, uint min_size) @inline
{
	arena.min_region_size = min_size;
}

<*
	Reclaim all used memory, allowing to use it freely again
*>
fn void ArenaAlloc.reset(&arena)
{
	foreach (&reg : arena.regions) {
		reg.cursor = 0;
	}
}

<*
	Destroy all the memory storage of arena and return it to OS
*>
fn void ArenaAlloc.destroy(&arena)
{
	foreach (&reg : arena.regions) {
		reg.cursor = 0;
		allocator::free(arena.backing_alloc, reg.data.ptr);
	}
	arena.regions.free();
}

fn ArenaRegion create_region(ArenaAlloc* arena, usz size) @local
{
	ArenaRegion reg;
	if (arena.alloc_init_type == AllocInitType.ZERO) {
		reg.data = allocator::new_array(arena.backing_alloc, char, math::max(size, (usz)arena.min_region_size));
	} else {
		reg.data = allocator::alloc_array(arena.backing_alloc, char, math::max(size, (usz)arena.min_region_size));
	}
	return reg;
}

fn bool ArenaRegion.owns_ptr(&reg, void* ptr) @inline @local
{
	return (uptr)ptr >= (uptr)reg.data.ptr && (uptr)ptr < (uptr)reg.data.ptr + reg.data.len;
}

fn usz ArenaRegion.remain_mem(&reg) @inline @local
{
	return reg.data.len - reg.cursor;
}

fn bool ArenaRegion.is_last_alloc(&reg, void* ptr, usz alloc_size) @inline @local
{
	usz alloc_cursor = (usz)(ptr + alloc_size) - (usz)reg.data.ptr;
	return alloc_cursor == reg.cursor;
}

