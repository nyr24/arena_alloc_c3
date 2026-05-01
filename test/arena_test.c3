module arena_test @test;

import nyr_allocators::arena;
import std::collections::map;

fn void temp_scope()
{
	ArenaAlloc arena;
	arena.init(mem);
	defer arena.free();

	arena.@temp_scope(; alloc)
	{
		char[] mem1 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem1);
		log_alloc(mem1, "mem1");

		char[] mem2 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem2);
		log_alloc(mem2, "mem2");

		char[] mem3 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem3);
		log_alloc(mem3, "mem3");

		char[] mem4 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem4);
		log_alloc(mem4, "mem4");
	};
}

fn void map_test()
{
	ArenaAlloc arena;
	arena.init(mem);
	defer arena.free();
	Allocator a = &arena;
	
	HashMap{String, uint} map;
	map.init(a);

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

// Helpers

module arena_test;
import std::math::random;
import std::io;

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

