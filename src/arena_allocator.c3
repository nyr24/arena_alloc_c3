module nyr_allocators::arena;
import std::math;
import std::io;
import std::collections::list;

// Individual allocation structure: [size=8bytes|payload|padding]

const DEFAULT_REGION_SIZE @local = 4096;
const MIN_REGION_SIZE     @local = 1024;

struct ArenaAlloc (Allocator, Printable)
{
	List{ArenaRegion} regions;
	Allocator backing_alloc;
	uint last_region_ind;
	uint snapshot_count;
	uint min_region_size;
}

struct ArenaRegion @local
{
	char[] data;
	uint cursor;
}

struct ArenaSnapshot
{
	uint region;
	uint cursor;
}

<*
 Initializes the arena.

 @require init_region_capacity >= 1 : "Should be at least one"
 @require min_region_size >= MIN_REGION_SIZE : "Shouldn't be less than this"
 @require first_region_size >= MIN_REGION_SIZE : "Shouldn't be less than this"
*>
fn void ArenaAlloc.init(
	&arena,
	Allocator backing_alloc,
	uint min_region_size = DEFAULT_REGION_SIZE,
	uint first_region_size = DEFAULT_REGION_SIZE,
	sz init_region_capacity = 1,
)
{
	arena.backing_alloc = backing_alloc;
	arena.min_region_size = min_region_size;
	arena.regions.init(backing_alloc, init_region_capacity);
	push_region(arena, first_region_size);
}

<*
 Acquire memory from the allocator, with the given alignment and initialization type.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require size > 0 : "The size must be 1 or more"
 @return ? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.acquire(&arena, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	sz aligned_size_with_header = mem::aligned_offset(size + allocators::DEFAULT_SIZE_PREFIX, alignment);
	sz aligned_size = aligned_size_with_header - allocators::DEFAULT_SIZE_PREFIX;
	ArenaRegion* region = null;
	uint reg_ind = arena.snapshot_count > 0 ? arena.last_region_ind : 0;

	for (; reg_ind < arena.regions.size; ++reg_ind)
	{
		ArenaRegion* curr = &arena.regions[reg_ind];
		if (aligned_size <= remain_mem(curr))
		{
			region = curr;
			break;
		}
	}

	if (!region)
	{
		sz last_ind = push_region(arena, aligned_size_with_header);
		region = &arena.regions[last_ind];
	}

	return finalize_alloc(arena, region, aligned_size, reg_ind, init_type);
}

<*
 Resize acquired memory from the allocator, with the given new size and alignment.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require ptr != null
 @require new_size > 0
 @return ? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.resize(&arena, void* ptr, sz new_size, sz alignment = 0) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	sz aligned_new_size_with_header = mem::aligned_offset(new_size + allocators::DEFAULT_SIZE_PREFIX, alignment);
	sz aligned_new_size = aligned_new_size_with_header - allocators::DEFAULT_SIZE_PREFIX;
	ArenaRegion* reg = null;
	uint reg_ind = 0;

	foreach (uint i, &curr_reg : arena.regions)
	{
		if (curr_reg.owns_ptr(ptr))
		{
			reg = curr_reg;
			reg_ind = i;
			break;
		}
	}

	assert(ptr != null, "Pointer isn't managed by this allocator");

	sz* old_size = (sz*)((char*)ptr - allocators::DEFAULT_SIZE_PREFIX);
	sz alloc_size_diff = aligned_new_size - *old_size;
	bool last_alloc = reg.is_last_alloc(ptr, *old_size);

	// if allocation was last one in this region
	if ALLOCATE_NEW: (last_alloc)
	{
		bool alloc_fits_curr_reg = (alloc_size_diff < 0) ? true : (reg.cursor + alloc_size_diff) <= reg.data.len;
		if (!alloc_fits_curr_reg)
		{
			// free this alloc and jump
			reg.cursor -= (uint)(*old_size + allocators::DEFAULT_SIZE_PREFIX);
			break ALLOCATE_NEW;
		}
		*old_size = aligned_new_size;
		reg.cursor += (uint)alloc_size_diff;
		return ptr;
	}

	// if allocation was NOT last one in this region try to feet it at the end
	if (!last_alloc)
	{
		bool enough_place_at_end = aligned_new_size_with_header <= remain_mem(reg);
		if (enough_place_at_end)
		{
			void* ret = finalize_alloc(arena, reg, aligned_new_size, reg_ind, NO_ZERO);
			mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
			return ret;
		}
	}

	void*? ret = arena.acquire(aligned_new_size, NO_ZERO, alignment);
	if (catch excuse = ret)
	{
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

	foreach (&curr_reg : arena.regions)
	{
		if (curr_reg.owns_ptr(ptr))
		{
			reg = curr_reg;
			break;
		}
	}

	if (!reg)
	{
		return;
	}

	sz* alloc_size = (sz*)(ptr - allocators::DEFAULT_SIZE_PREFIX);
	if (!reg.is_last_alloc(ptr, *alloc_size))
	{
		return;
	}
	reg.cursor -= (uint)(*alloc_size + allocators::DEFAULT_SIZE_PREFIX);
}

<*
 Ensure that arena has contiguous memory space of size 'cap'

 Use case for this: you know that you will have 'n' small allocations
 and you don't want to preallocate all the space for them in 'acquire' call,
 but made them as separate ones, still preserving opportunity for storing them in a single Region
*>
fn void ArenaAlloc.ensure_capacity(&arena, sz cap)
{
	sz alignment = mem::DEFAULT_MEM_ALIGNMENT;
	sz aligned_cap_with_header = mem::aligned_offset(cap + allocators::DEFAULT_SIZE_PREFIX, alignment);
	ArenaRegion* region = null;
	uint reg_ind = arena.snapshot_count > 0 ? arena.last_region_ind : 0;

	for (; reg_ind < arena.regions.size; ++reg_ind)
	{
		ArenaRegion* curr = &arena.regions[reg_ind];
		if (aligned_cap_with_header <= remain_mem(curr))
		{
			arena.last_region_ind = math::max(arena.last_region_ind, reg_ind);
			return;
		}
	}

	// didn't found sufficient region, acquire new one
	push_region(arena, aligned_cap_with_header);
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
	for (sz i = arena.last_region_ind; i > snapshot.region; --i)
	{
		arena.regions[i].cursor = 0;
	}
	arena.regions[snapshot.region].cursor = snapshot.cursor;
	arena.last_region_ind = snapshot.region;
	arena.snapshot_count--;
}

<*
 Create a temporary allocation scope, all allocated memory will be freed at the end of this scope.
*>
macro ArenaAlloc.@temp_scope(&arena; @body(Allocator alloc))
{
	ArenaSnapshot sn = arena.create_snapshot();
	defer arena.rewind_snapshot(sn);
	@body(arena);
}

<*
 Reclaim all used memory, allowing for reuse.
*>
fn void ArenaAlloc.reset(&arena)
{
	foreach (&reg : arena.regions)
	{
		reg.cursor = 0;
	}
}

<*
 Free all the memory storage of arena and return it to backing allocator.
*>
fn void ArenaAlloc.free(&arena)
{
	foreach (&reg : arena.regions)
	{
		reg.cursor = 0;
		alloc::free(arena.backing_alloc, reg.data.ptr);
	}
	arena.regions.free();
}

<*
 Convenient access to 'Allocator' interface.
*>
fn Allocator ArenaAlloc.allocator(&arena) @inline
{
	return (Allocator)arena;
}

<*
 Set the size that will be used as 'min' capacity boundary for newly created arena region.
*>
fn void ArenaAlloc.set_min_region_size(&arena, uint min_size) @inline
{
	arena.min_region_size = min_size;
}

fn sz? ArenaAlloc.to_format(&arena, Formatter* fmt) @dynamic
{
	sz total = fmt.print("Arena allocator info:")!;

	foreach (sz i, reg : arena.regions)
	{
		fmt.printf("\n\tRegion %s: [%s : %s], free space: %s", i, reg.cursor, reg.data.len, remain_mem(&reg))!;
	}

	return total;
}

// ------ Private API ------

<*
 Insert allocation after region.cursor.
*>
fn void* finalize_alloc(
	ArenaAlloc* arena,
	ArenaRegion* reg,
	sz aligned_size,
	uint reg_ind,
	AllocInitType init_type
) @inline @local
{
	void* ret = reg.data.ptr + reg.cursor + allocators::DEFAULT_SIZE_PREFIX;
	sz* header = (sz*)(ret - allocators::DEFAULT_SIZE_PREFIX);
	*header = aligned_size;
	reg.cursor += (uint)(aligned_size + allocators::DEFAULT_SIZE_PREFIX);
	arena.last_region_ind = math::max(arena.last_region_ind, reg_ind);
	if (init_type == ZERO)
	{
		mem::clear(ret, aligned_size);
	}
	return ret;
}

<*
 Add new region to the arena.
*>
fn uint push_region(ArenaAlloc* arena, sz size) @inline @local
{
	arena.regions.push(create_region(arena, size));
	arena.last_region_ind = math::max(arena.last_region_ind, (uint)(arena.regions.size - 1));
	return arena.last_region_ind;
}

<*
 Initialize arena region.
*>
fn ArenaRegion create_region(ArenaAlloc* arena, sz size) @private
{
	ArenaRegion reg;
	reg.data = alloc::alloc_array(arena.backing_alloc, char, math::max(size, (sz)arena.min_region_size));
	return reg;
}

<*
 Tell if provided pointer is owned by this allocator memory.
*>
fn bool ArenaRegion.owns_ptr(&reg, void* ptr) @inline
{
	return (uptr)ptr >= (uptr)reg.data.ptr && (uptr)ptr < (uptr)reg.data.ptr + reg.data.len;
}

<*
 Tell how much free memory arena region has.
*>
fn sz remain_mem(ArenaRegion* reg) @inline @local
{
	return reg.data.len - reg.cursor;
}

<*
 Tell if provided allocation is last in the region.
*>
fn bool ArenaRegion.is_last_alloc(&reg, void* ptr, sz alloc_size) @inline
{
	sz alloc_cursor = (sz)(ptr + alloc_size) - (sz)reg.data.ptr;
	return alloc_cursor == reg.cursor;
}
