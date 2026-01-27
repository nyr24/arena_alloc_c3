### Dynamic Arena Allocator implementation for C3 programming language

### Features:
-  individual stack-like deallocation on demand
-  snapshots - for making a bunch of temporary allocations and then reclaiming them
-  memory reserving through 'ensure_capacity'
-  fully configurable: you can choose min_region_size, zeroing out memory or not to, backing allocator for regions
