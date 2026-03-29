module arena;

import std::io;
import std::math::random;
import std::collections::map;

fn void fill_alloc(char[] alloc)
{
	uint rn = random::rand(128u);
	uint rn2 = random::rand(128u);

	for (uint ii = 0; ii < alloc.len; ++ii)
	{
		alloc[ii] = (ii & 1) == 0 ? (char)rn : (char)rn2;
	}
}

fn void log_alloc(char[] alloc, String name = "unknown")
{
	io::printfn("Alloc: %s", name);
	for (uint i = 0; i < 3; ++i)
	{
		uint r_n = rand(alloc.len);
		io::printf("%c", alloc[r_n]);
	}
	io::printn();
}

fn void main_test() @test
{
	ArenaAlloc arena;
	arena.init(mem);
	defer arena.destroy();

	const EXAMPLE_1          = false;
	const EXAMPLE_ENSURE     = false;
	const EXAMPLE_TEMP_SCOPE = true;
	const EXAMPLE_MAP = true;

	if (EXAMPLE_1)
	{
		example_1(&arena);
	}

	if (EXAMPLE_ENSURE)
	{
		example_ensure(&arena);
	}

	if (EXAMPLE_TEMP_SCOPE)
	{
		example_temp_scope(&arena);
	}

	if (EXAMPLE_MAP)
	{
		example_map(&arena);
	}
}

fn void example_temp_scope(ArenaAlloc* arena)
{
	arena.ensure_capacity(1000);

	arena.@temp_scope(; alloc)
	{
		char[] mem1 = allocator::alloc_array(alloc, char, 200);
		fill_alloc(mem1);
		log_alloc(mem1, "mem1");

		char[] mem2 = allocator::alloc_array(alloc, char, 200);
		fill_alloc(mem2);
		log_alloc(mem2, "mem2");

		char[] mem3 = allocator::alloc_array(alloc, char, 200);
		fill_alloc(mem3);
		log_alloc(mem3, "mem3");

		char[] mem4 = allocator::alloc_array(alloc, char, 200);
		fill_alloc(mem4);
		log_alloc(mem4, "mem4");
	};
}

fn void example_1(ArenaAlloc* _arena)
{
	Allocator arena = _arena;

	char[] mem1 = arena.acquire(800, NO_ZERO)!![:800];
	fill_alloc(mem1);
	log_alloc(mem1, "mem1");

	char[] mem2 = arena.acquire(900, NO_ZERO)!![:900];
	fill_alloc(mem2);
	log_alloc(mem2, "mem2");

	char[] mem3 = arena.acquire(1600, NO_ZERO)!![:1600];
	fill_alloc(mem3);
	log_alloc(mem3, "mem3");

	arena.release(mem3.ptr, false);

	mem2 = arena.resize(mem2.ptr, 1000)!![:1000];
	fill_alloc(mem2);
	log_alloc(mem2, "mem2, #2");

	mem1 = arena.resize(mem1.ptr, 100)!![:100];
	fill_alloc(mem1);
	log_alloc(mem1, "mem1, #2");

	_arena.ensure_capacity(3600);
	mem2 = arena.resize(mem2.ptr, 3600)!![:3600];
	fill_alloc(mem2);
	log_alloc(mem2, "mem2, #3");
}

fn void example_ensure(ArenaAlloc* _arena)
{
	Allocator arena = _arena;
	_arena.ensure_capacity(1000);
	ArenaSnapshot snap = _arena.create_snapshot();
	defer _arena.rewind_snapshot(snap);

	char[] mem1 = allocator::alloc_array(arena, char, 100);
	fill_alloc(mem1);
	log_alloc(mem1, "mem1");

	char[] mem2 = allocator::alloc_array(arena, char, 500);
	fill_alloc(mem2);
	log_alloc(mem2, "mem2");

	char[] mem3 = allocator::alloc_array(arena, char, 700);
	fill_alloc(mem3);
	log_alloc(mem3, "mem3");

	char[] mem4 = allocator::alloc_array(arena, char, 800);
	fill_alloc(mem4);
	log_alloc(mem4, "mem4");
}

fn void example_map(ArenaAlloc* arena)
{
	Allocator a = arena.allocator();
	HashMap{String, uint} map;
	map.init(a, 100, 1.0);

	String[*] keys = {
		"hello", "world", "third"
	};
	uint[*] vals = {
		23, 245, 5469,
	};

	for (uint i = 0; i < keys.len; ++i)
	{
		map.set(keys[i], vals[i]);
	}

	for (uint i = 0; i < keys.len; ++i)
	{
		assert(map.get(keys[i])!! == vals[i]);
	}
}
