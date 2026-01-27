module arena;

import std::io;
import std::math::random;

fn void fill_alloc(char[] alloc)
{
	uint rn = random::rand(128u);
	uint rn2 = random::rand(128u);

	for (uint ii = 0; ii < alloc.len; ++ii) {
		alloc[ii] = (ii & 1) == 0 ? (char)rn : (char)rn2;
	}
}

fn void log_alloc(char[] alloc, String name = "unknown")
{
	io::printfn("Alloc: %s", name);
	for (uint i = 0; i < 3; ++i) {
		uint r_n = rand(alloc.len);
		io::printf("%c", alloc[r_n]);
	}
	io::printn();
}

fn int main(String[] args)
{
	ArenaAlloc _arena;
	_arena.init(mem);
	defer _arena.destroy();

	Allocator arena = &_arena;

	{
		char[] mem1 = arena.acquire(600, NO_ZERO)!![:600];
		fill_alloc(mem1);
		log_alloc(mem1, "mem1");
	}

	{
		_arena.ensure_capacity(1000);
		ArenaSnapshot snap = _arena.create_snapshot();
		defer _arena.rewind_snapshot(snap);

		char[] mem1 = _arena.acquire(100, NO_ZERO)!![:100];
		fill_alloc(mem1);
		log_alloc(mem1, "mem1");

		char[] mem2 = arena.acquire(500, NO_ZERO)!![:500];
		fill_alloc(mem2);
		log_alloc(mem2, "mem2");

		char[] mem3 = arena.acquire(700, NO_ZERO)!![:700];
		fill_alloc(mem3);
		log_alloc(mem3, "mem3");

		char[] mem4 = arena.acquire(800, NO_ZERO)!![:800];
		fill_alloc(mem4);
		log_alloc(mem4, "mem4");
	}

	exmp_1(arena);

	return 0;
}

fn void exmp_1(Allocator arena)
{
	ArenaAlloc* _arena = (ArenaAlloc*)arena;

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
