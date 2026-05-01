module nyr_allocators::arena;
import std::math;
import std::io;

// Individual allocation structure: [header|payload|padding]

const DEFAULT_REGION_SIZE  @local = 4096;
const MIN_REGION_SIZE      @local = 512;
const DEFAULT_REGION_COUNT @local = 2; 
const HEADER_SIZE          @local = allocators::DEFAULT_SIZE_PREFIX;

struct ArenaAlloc (Allocator, Printable)
{
	ArenaRegion* regions;
	ArenaRegion* last_region;
	Allocator backing_alloc;
	sz last_region_ind;
	sz snapshot_count;
	sz min_region_size;
}

struct ArenaRegion @local
{
	sz capacity;
	sz cursor;
	ArenaRegion* next;
	ArenaRegion* prev;
	char[*] memory;
}

struct ArenaSnapshot
{
	ArenaRegion* region;
	sz cursor;
}

<*
 Initializes the arena.

 @require min_region_size >= MIN_REGION_SIZE : "Shouldn't be less than this"
 @require first_region_size >= MIN_REGION_SIZE : "Shouldn't be less than this"
*>
fn void ArenaAlloc.init(
	&arena,
	Allocator backing_alloc,
	sz min_region_size = DEFAULT_REGION_SIZE,
	sz first_region_size = DEFAULT_REGION_SIZE,
)
{
	*arena = { };
	arena.backing_alloc = backing_alloc;
	arena.min_region_size = min_region_size;
	// First region initialized here, so we don't need to check if there'is a 'head' in 'push_region' every time.
	arena.regions = allocate_region(arena, first_region_size);
	arena.last_region = arena.regions;
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
	sz aligned_size_with_header = mem::aligned_offset(alignment + HEADER_SIZE + size, mem::DEFAULT_MEM_ALIGNMENT);
	sz aligned_size = aligned_size_with_header - HEADER_SIZE;
	ArenaRegion* curr = arena.snapshot_count > 0 ? arena.last_region : arena.regions;
	ArenaRegion* sufficient_reg = null;

	while (curr)
	{
		if (aligned_size <= remain_mem(curr))
		{
			sufficient_reg = curr;
			break;
		}
	}

	if (!sufficient_reg)
	{
		sufficient_reg = push_region(arena, aligned_size_with_header);
	}

	return finalize_alloc(arena, sufficient_reg, aligned_size, alignment, init_type);
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
	sz aligned_new_size = mem::aligned_offset(new_size, mem::DEFAULT_MEM_ALIGNMENT);
	ArenaRegion* curr = arena.regions;
	ArenaRegion* reg = null;

	while (curr)
	{
		if (owns_ptr(curr, ptr))
		{
			reg = curr;
			break;
		}
	}

	assert(reg != null, "Pointer isn't managed by this allocator");

	sz* old_size = (sz*)((char*)ptr - HEADER_SIZE);
	sz alloc_size_diff = aligned_new_size - *old_size;
	bool last_alloc = is_last_alloc(reg, ptr, *old_size);

	// if allocation was last one in this region
	if ALLOCATE_NEW: (last_alloc)
	{
		bool alloc_fits_curr_reg = (alloc_size_diff < 0) ? true : (reg.cursor + alloc_size_diff) <= reg.capacity;
		if (!alloc_fits_curr_reg)
		{
			// free this alloc and jump
			reg.cursor -= (sz)(*old_size + HEADER_SIZE);
			break ALLOCATE_NEW;
		}
		*old_size = aligned_new_size;
		reg.cursor += alloc_size_diff;
		return ptr;
	}
	// if allocation was NOT last one in this region try to feet it at the end
	else
	{
		alignment = allocators::alignment_for_allocation(alignment);
		sz aligned_size_with_header = mem::aligned_offset(alignment + new_size + HEADER_SIZE, mem::DEFAULT_MEM_ALIGNMENT);
		bool enough_place_at_end = aligned_size_with_header <= remain_mem(reg);
		if (enough_place_at_end)
		{
			sz aligned_size = aligned_size_with_header - HEADER_SIZE;
			void* ret = finalize_alloc(arena, reg, aligned_size, alignment, NO_ZERO);
			mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
			return ret;
		}
	}

	void* ret = arena.acquire(new_size, NO_ZERO, alignment)!;
	mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
	return ret;
}

<*
 Release memory acquired using `acquire` or `resize`.
 It is not a good practice to free individual pointers from arena
 Consider using snapshots, @temp_scope, or resetting whole arena.

 @require ptr != null : "Empty pointers should never be released"
*>
fn void ArenaAlloc.release(&arena, void* ptr, bool) @dynamic
{
	ArenaRegion* curr = arena.regions;
	ArenaRegion* reg = null;

	while (curr)
	{
		if (owns_ptr(curr, ptr))
		{
			reg = curr;
			break;
		}
	}

	assert(reg, "Pointer isn't managed by this allocator");

	sz* alloc_size = (sz*)(ptr - HEADER_SIZE);
	if (!is_last_alloc(reg, ptr, *alloc_size))
	{
		return;
	}
	reg.cursor -= (sz)(*alloc_size + HEADER_SIZE);
}

<*
 Create a 'mark' from which you can start doing temporary allocations,
 then easily reclaim them back with 'rewind_snapshot'
*>
fn ArenaSnapshot ArenaAlloc.create_snapshot(&arena)
{
	ArenaSnapshot snap;
	snap.region = arena.last_region;
	snap.cursor = arena.last_region.cursor;
	arena.snapshot_count++;
	return snap;
}

<*
 Reclaim all memory used since a call to 'create_snapshot'

 @require snapshot.region != null : "Shouldn't be null"
*>
fn void ArenaAlloc.rewind_snapshot(&arena, ArenaSnapshot snapshot)
{
	ArenaRegion* curr = arena.last_region;

	while (curr && curr != snapshot.region)
	{
		curr.cursor = 0;
		curr = curr.prev;
	}

	assert(curr != null && curr == snapshot.region, "Should be provided region");
	curr.cursor = snapshot.cursor;
	arena.last_region = curr;
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
	ArenaRegion* curr = arena.regions;

	while (curr)
	{
		curr.cursor = 0;
		curr = curr.next;
	}

	arena.last_region = arena.regions;
}

<*
 Free all the memory storage of arena and return it to backing allocator.

 @require arena.regions != null : "Should be initialized"
*>
fn void ArenaAlloc.free(&arena)
{
	ArenaRegion* curr = arena.regions;
	ArenaRegion* next = null;

 	while (curr)
	{
		next = curr.next;
		alloc::free(arena.backing_alloc, curr);
		curr = next;
	}

	arena.regions = null;
	arena.last_region = null;
}

<*
 Set the size that will be used as 'min' capacity boundary for newly created arena region.

 @require min_size >= MIN_REGION_SIZE : "Should be greater than min"
*>
fn void ArenaAlloc.set_min_region_size(&arena, sz min_size) @inline
{
	arena.min_region_size = min_size;
}

<*
 Implements 'Printable' interface.
*>
fn sz? ArenaAlloc.to_format(&arena, Formatter* fmt) @dynamic
{
	sz total = fmt.print("Arena allocator info: [cursor : capacity]")!;
	ArenaRegion* curr = arena.regions;

	while (curr)
	{
		fmt.printf("\n\t[%s : %s], remain: %s", curr.cursor, curr.capacity, remain_mem(curr))!;
		curr = curr.next;
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
	sz alignment,
	AllocInitType init_type,
) @inline @local
{
	char* start = (char*)&reg.memory + reg.cursor + HEADER_SIZE;
	char* ret = mem::aligned_pointer(start, alignment);
	sz* header = (sz*)(ret - HEADER_SIZE);
	*header = aligned_size;
	reg.cursor += aligned_size + HEADER_SIZE;
	if (init_type == ZERO)
	{
		mem::clear(ret, aligned_size);
	}
	return ret;
}

<*
 Add new region to the arena.

 @require arena.last_region != null : "Shouldn't be null"
*>
fn ArenaRegion* push_region(ArenaAlloc* arena, sz size) @local
{
	ArenaRegion* curr = arena.last_region;
	ArenaRegion* prev = curr;

	while (curr)
	{
		prev = curr;
		curr = curr.next;
	}

	assert(prev, "Shouldn't be null");

	curr = allocate_region(arena, size);
	curr.prev = prev;
	prev.next = curr;

	arena.last_region = curr;
	return curr;
}

<*
 Allocate new arena region.
*>
fn ArenaRegion* allocate_region(ArenaAlloc* arena, sz size) @local
{
	sz cap = math::max(size, arena.min_region_size);
	sz aligned_cap = mem::aligned_offset(cap, mem::DEFAULT_MEM_ALIGNMENT);
	ArenaRegion* reg = alloc::alloc_with_padding(arena.backing_alloc, ArenaRegion, aligned_cap)!!;
	reg.capacity = aligned_cap;
	reg.cursor = 0;
	reg.next = null;
	reg.prev = null;
	return reg;
}

<*
 Tell if provided pointer is owned by this allocator memory.
*>
fn bool owns_ptr(ArenaRegion* reg, void* ptr) @inline @local
{
	return ((uptr)ptr >= (uptr)&reg.memory) && ((uptr)ptr < ((uptr)&reg.memory + reg.capacity));
}

<*
 Tell how much free memory arena region has.
*>
fn sz remain_mem(ArenaRegion* reg) @inline @local
{
	return reg.capacity - reg.cursor;
}

<*
 Tell if provided allocation is last in the region.
*>
fn bool is_last_alloc(ArenaRegion* reg, void* ptr, sz alloc_size) @inline @local
{
	sz alloc_cursor = ((char*)ptr + alloc_size) - (char*)&reg.memory;
	return alloc_cursor == reg.cursor;
}
