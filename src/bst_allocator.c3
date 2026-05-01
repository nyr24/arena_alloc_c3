module nyr_allocators::bst;
import std::io;
import std::math;

const DEFAULT_CAPACITY	   = 4096;
const MIN_BLOCK_SIZE       = mem::DEFAULT_MEM_ALIGNMENT + FreeNode::size;
const MIN_CAPACITY         = MIN_BLOCK_SIZE * 4;

<*
 Binary search tree allocator is an allocator that preallocates a large block of memory and embeds a binary search tree to enable efficient searching for available blocks.
 After a deallocation, it performs coalescing of adjacent nodes when possible.
 The user can choose between two strategies: best fit and first fit. Best fit minimizes memory fragmentation but is generally slower than the first fit strategy.
 The allocator uses a binary search tree as its underlying data structure to enable efficient node lookup.
 When the allocator exhausts its memory or fragmentation becomes too high, it falls back to its backing allocator. Fallback allocations are automatically freed when the allocator is destroyed; the user must not free them manually.
 Fallback allocations can also be resized.
*>
struct BSTAlloc (Allocator, Printable)
{
	char* data;
	sz capacity;
	FreeNode* root;
	FallbackAlloc* fallback_root;
	BSTAllocStrategy strategy;
	Allocator backing_alloc;
}

enum BSTAllocStrategy
{
	BEST_FIT,
	FIRST_FIT,
}

bitstruct NodeState : sz @local
{
	// Embeds 'is_free' inside of 'size' to reduce memory usage.
	bool is_free : 0..0;
	// Aligned size of memory block + AllocHeader.
	sz size : 1..(bitsizeof(sz) - 1);
}

struct FreeNode @local
{
 	// Uncomment this and comment '_state' for better debug info.
	// bool is_free;
	// sz size;
	inline NodeState _state;
	FreeNode* prev_phys;
	// Overwritten on allocation.
	FreeNode* left;
	FreeNode* right;
	// Store parent to perform deletions in constant time.
	FreeNode* parent;
}

struct AllocHeader @local
{
 	// Uncomment this and comment '_state' for better debug info.
	// bool is_free;
	// sz size;
	inline NodeState _state;
	FreeNode* prev_phys;
}

struct FallbackAlloc @local
{
	FallbackAlloc* next;
	sz size;
	char[*] memory;
}

<*
 Initializes bst allocator structure.

 @require init_capacity > MIN_CAPACITY : "Capacity should be greater than minimum capacity"
*>
fn void BSTAlloc.init(
	&self,
	Allocator backing_alloc = mem,
	sz init_capacity = DEFAULT_CAPACITY,
	BSTAllocStrategy strategy = BEST_FIT,
)
{
	self.capacity = mem::aligned_offset(init_capacity, mem::DEFAULT_MEM_ALIGNMENT);
	self.data = (char*)alloc::alloc_with_padding(backing_alloc, AllocHeader, self.capacity)!!;
	self.backing_alloc = backing_alloc;
	self.strategy = strategy;
	self.reset();
}

<*
 Implements the Allocator interface method.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require size > 0
*>
fn void*? BSTAlloc.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	sz aligned_size = mem::aligned_offset(size + AllocHeader::size, alignment);

	FreeNode* node = null;

	if (self.strategy == BEST_FIT)
	{
		node = find_node_best_fit(self, aligned_size);
	}
	else
	{
		node = find_node_first_fit(self, aligned_size);
	}

	if (!node)
	{
		return make_fallback_allocation(self, aligned_size, init_type)!;
	}

	remove_node(&self.root, node);

	// Try to insert a new node, if have enough space.
	sz diff = node.size - aligned_size;
	if (@likely(diff >= MIN_BLOCK_SIZE))
	{
		FreeNode* new_node = node_at_offset(node, aligned_size);
		init_node(new_node, diff, node);
		insert_node(&self.root, new_node);
		node.size = aligned_size;
	}

	if (init_type == ZERO)
	{
		mem::clear((AllocHeader*)node + 1, aligned_size - AllocHeader::size);
	}

	return (void*)((AllocHeader*)node + 1);
}

<*
 Implements the Allocator interface method.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require old_pointer != null
 @require size > 0
 @return ? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BSTAlloc.resize(&self, void* old_pointer, sz size, sz alignment) @dynamic
{
	if (@unlikely(!owns_pointer(self, old_pointer)))
	{
		return resize_fallback_allocation(self, old_pointer, size);
	}

	FreeNode* node = (FreeNode*)((AllocHeader*)old_pointer - 1);
	sz old_size = node.size;
	alignment = allocators::alignment_for_allocation(alignment);
	sz new_size = mem::aligned_offset(size + AllocHeader::size, alignment);

	// Shrink.
	if (@unlikely(new_size <= old_size))
	{
		sz diff = old_size - new_size;
		node.size -= diff;
		if (diff >= MIN_BLOCK_SIZE)
		{
			FreeNode* new_node = node_next(node);
			init_node(new_node, diff, node);
			insert_node(&self.root, new_node);
		}
		return old_pointer;
	}

	FreeNode* next = node_next(node);

	// Try to extend.
	if (next < tail_ref(self) && next.is_free)
	{
		sz diff = mem::aligned_offset(new_size - old_size, alignment);
		sz new_node_size = next.size - diff;
		FreeNode* new_node = null;
		// Insert a new node if have enough space.
		if (new_node_size >= MIN_BLOCK_SIZE)
		{
			node.size += diff;
			new_node = node_next(node);
			init_node(new_node, new_node_size, node);
			remove_node(&self.root, next);
			insert_node(&self.root, new_node);
		}
		// Or just consume all space of the next node.
		else
		{
			node.size += next.size;
			remove_node(&self.root, next);
		}
		return old_pointer;
	}

	// Allocate a new one.
	void* new_allocation = self.acquire(size, NO_ZERO, alignment)!;
	mem::copy(new_allocation, old_pointer, old_size - AllocHeader::size);
	self.release(old_pointer, false);

	return new_allocation;
}

<*
 Implements the Allocator interface method.

 @require ptr != null : "Shouldn't be null"
*>
fn void BSTAlloc.release(&self, void* ptr, bool) @dynamic
{
	if (!owns_pointer(self, ptr)) return;
	FreeNode* free_node = (FreeNode*)((AllocHeader*)ptr - 1);
	// Prevent double free.
	if (@unlikely(free_node.is_free)) return;

	// Zero previously allocated memory.
	free_node.parent = null;
	free_node.left = null;
	free_node.right = null;

	// Order of this lines should be preserved.
	free_node = coalesce_nodes_around(self, free_node);
	insert_node(&self.root, free_node);
}

<*
 Frees resources of the allocator.
*>
fn void BSTAlloc.free(&self)
{
	if (@likely(self.data != null))
	{
		alloc::free(self.backing_alloc, self.data);
	}
	if (self.fallback_root)
	{
		free_fallback_allocations(self);
	}
	*self = { };
}

<*
 Resets the state of the allocator making it available for reuse.
*>
fn void BSTAlloc.reset(&self)
{
	self.root = (FreeNode*)self.data;
	init_node(self.root, self.capacity, null);
}

<*
 Implements 'Printable' interface.

 @require self.root != null : "Must be initialized"
 @require tail_ref(self) != null : "Must be initialized"
*>
fn sz? BSTAlloc.to_format(&self, Formatter* fmt) @dynamic
{
	sz total = fmt.print("Binary tree allocator info:")!;
	sz main_buff_used = 0;

	if (!self.root) {
		total += fmt.print("[Empty Buffer]")!;
		return total;
	};

	FreeNode* curr = (FreeNode*)self.data;
	FreeNode* tail = tail_ref(self);
	String usage_s;

	while (curr && curr < tail)
	{
		if (!curr.is_free)
		{
			usage_s = "used";
			main_buff_used += curr.size;
		}
		else
		{
			usage_s = "free";
		}
		total += fmt.printf("\n\t[%s : %sB]", usage_s, curr.size)!;
		curr = node_next(curr);
	}

	total += fmt.print("\n--- Block report finished ---\n")!;
	total += print_total_usage(self, fmt, main_buff_used)!;

	return total;
}

<*
 Print total memory usage statistics.
*>
fn sz? print_total_usage(BSTAlloc* self, Formatter* fmt, sz main_buff_used) @local
{
	sz fallback_used = calc_used_fallback_mem(self);
	sz main_buff_remain = self.capacity - main_buff_used;
	String fmt_string = "Total usage:\n\tmemory total  = %.0fB / %.2fKiB / %.3fMiB / %.4fGiB\n\tmemory used   = %.0fB / %.2fKiB / %.3fMiB / %.4fGiB\n\tmemory remain = %.0fB / %.2fKiB / %.3fMiB / %.4fGiB\n\textra allocated = %.0fB / %.2fKiB / %.3fMiB / %.4fGiB";

	return fmt.printf(
		fmt_string,
		(float)self.capacity,
		self.capacity / (float)mem::KB,
		self.capacity / (float)mem::MB,
		self.capacity / (float)mem::GB,
		(float)main_buff_used,
		main_buff_used / (float)mem::KB,
		main_buff_used / (float)mem::MB,
		main_buff_used / (float)mem::GB,
		(float)main_buff_remain,
		main_buff_remain / (float)mem::KB,
		main_buff_remain / (float)mem::MB,
		main_buff_remain / (float)mem::GB,
		(float)fallback_used,
		fallback_used / (float)mem::KB,
		fallback_used / (float)mem::MB,
		fallback_used / (float)mem::GB,
	);
}

// ------ Private API ------

<*
 Tries to find node based on best fit strategy.
 (node with minimal required space is returned).
*>
fn FreeNode* find_node_best_fit(BSTAlloc* self, sz req_size) @local
{
	if (!self.root) return null;

	FreeNode* curr = self.root;
	FreeNode* tail = tail_ref(self);
	FreeNode* best_node = null;

	while (curr && curr < tail)
	{
		if (curr.size >= req_size)
		{
			best_node = curr;
			curr = curr.left;
		}
		else
		{
			curr = curr.right;
		}
	}

	return best_node;
}

<*
 Tries to find node based on first fit strategy.
 (first appropriate node is returned).
*>
fn FreeNode* find_node_first_fit(BSTAlloc* self, sz req_size) @local
{
	if (!self.root) return null;

	FreeNode* curr = self.root;
	FreeNode* tail = tail_ref(self);

	while (curr && curr < tail)
	{
		if (curr.size >= req_size)
		{
			return curr;
		}
		else
		{
			curr = curr.right;
		}
	}

	return null;
}

<*
 Initializes new node and sets its state to 'free'.
*>
fn void init_node(FreeNode* node, sz size, FreeNode* prev_phys) @local
{
	*node = { };
	node.is_free = true;
	node.size = size;
	node.prev_phys = prev_phys;
}

<*
 BST insertion.
 Inserts the node into the tree of free nodes, making it available for future allocations.
*>
fn void insert_node(FreeNode** root, FreeNode* new_node) @local
{
	new_node.is_free = true;

	if (!*root)
	{
		*root = new_node;
		return;
	}

	FreeNode* curr = *root;

	while (curr)
	{
		if (new_node.size >= curr.size)
		{
			if (curr.right)
			{
				curr = curr.right;
			}
			else
			{
				curr.right = new_node;
				new_node.parent = curr;
				return;
			}
		}
		else
		{
			if (curr.left)
			{
				curr = curr.left;
			}
			else
			{
				curr.left = new_node;
				new_node.parent = curr;
				return;
			}
		}
	}
}

<*
 BST removal.
 Removes the node from the tree of free nodes, so its memory can be provided to the user.

 @require node_to_remove != null : "Shoudn't be null"
*>
fn void remove_node(FreeNode** root, FreeNode* node_to_remove) @local
{
	node_to_remove.is_free = false;

	if (*root == node_to_remove)
	{
		*root = null;
		return;
	}

	FreeNode* parent = node_to_remove.parent;

	if (node_to_remove == parent.left)
	{
		parent.left = null;
	}
	else
	{
		parent.right = null;
	}
}

<*
 Tries to coalesce adjacent nodes: (prev) -> (node) -> (next).

 @return "Returns node that was possibly moved to new address"
 @require node != null : "Shoudn't be null"
*>
fn FreeNode* coalesce_nodes_around(BSTAlloc* self, FreeNode* node) @local
{
	FreeNode* next = node_next(node);
	FreeNode* tail = tail_ref(self);
	bool was_merge = false;

	if (next < tail && next.is_free)
	{
		node.size += next.size;
		remove_node(&self.root, next);
		was_merge = true;
	}

	FreeNode* prev = node.prev_phys;
	if (prev && prev.is_free)
	{
		prev.size += node.size;
		node = prev;
		remove_node(&self.root, prev);
		was_merge = true;
	}

	if (was_merge)
	{
		next = node_next(node);
		if (next < tail)
		{
			next.prev_phys = node;
		}
	}

	return node;
}

<*
 Checks if provided pointer belongs to the bst allocator.

 @require ptr != null : "Shoudn't be null"
*>
fn bool owns_pointer(BSTAlloc* self, void* ptr) @inline @local
{
	return ptr >= self.data && ptr < (self.data + self.capacity);
}

<*
 Calculates position of the next node relatively to provided one, and returns it.

 @require node != null : "Shoudn't be null"
*>
fn FreeNode* node_next(FreeNode* node) @inline @local
{
	return (FreeNode*)((char*)node + node.size);
}

<*
 Calculates position of the node relatively to provided one with provided offset, and returns it.

 @require node != null : "Shoudn't be null"
 @require offset > 0 : "Should be bigger than 0"
*>
fn FreeNode* node_at_offset(FreeNode* node, sz offset) @inline @local
{
	return (FreeNode*)((char*)node + offset);
}

<*
 Returns a tail node of the allocator, which serves as a memory buffer boundary.
*>
fn FreeNode* tail_ref(BSTAlloc* self) @inline @local
{
	return (FreeNode*)(self.data + self.capacity);
}

<*
 Allocates to the separate linked list in case there's not enough space in the bst allocator main buffer.

 @require size > 0 : "Should be bigger than 0"
*>
fn void*? make_fallback_allocation(BSTAlloc* self, sz size, AllocInitType init_type) @local
{
	FallbackAlloc* curr = self.fallback_root;
	while (curr)
	{
		curr = curr.next;
	}
	curr = alloc::alloc_with_padding(self.backing_alloc, FallbackAlloc, size)!;
	curr.size = size;
	curr.next = null;

	if (!self.fallback_root)
	{
		self.fallback_root = curr;
	}

	if (init_type == ZERO)
	{
		mem::clear(&curr.memory, size);
	}

	return &curr.memory;
}

<*
 Tries to find and resize allocation made as a fallback.

 @require old_ptr != null : "Shouldn't be null"
 @require new_size > 0 : "Should be bigger than 0"
*>
fn void*? resize_fallback_allocation(BSTAlloc* self, void* old_ptr, sz new_size) @local
{
	FallbackAlloc* curr = self.fallback_root;
	FallbackAlloc* alloc = null;

	while (curr)
	{
		if (curr == old_ptr)
		{
			alloc = curr;
			break;
		}
		curr = curr.next;
	}

	assert(alloc != null, "Pointer originates from a different allocator: %p, not in %p - %p", old_ptr, self.data, self.data + self.capacity);

	alloc = alloc::realloc(self.backing_alloc, alloc, FallbackAlloc::size + new_size);
	alloc.size = new_size;

	return &alloc.memory;
}

<*
 Cleans up all fallback allocations.
*>
fn void free_fallback_allocations(BSTAlloc* self) @local
{
	FallbackAlloc* curr = self.fallback_root;
	while (curr)
	{
		FallbackAlloc* next = curr.next;
		alloc::free(self.backing_alloc, curr);
		curr = next;
	}
	self.fallback_root = null;
}

<*
 Calculates all memory that were allocated as a fallback.
*>
fn sz calc_used_fallback_mem(BSTAlloc* self) @local
{
	sz res = 0;
	FallbackAlloc* curr = self.fallback_root;
	while (curr)
	{
		res += curr.size;
		curr = curr.next;
	}
	return res;
}
