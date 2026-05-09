module thread_pool_test;

import data_structures::thread_pool;
import custom_allocators::arena;

import std::time;
import std::math;
import std::io;
import std::atomic;

fn void task_background(TaskData task) 
{
	String f_name = *(String*)task.data;

	ThreadArena* arena = (ThreadArena*)task.alloc;

	arena.@temp_scope(; alloc)
	{
		String contents = (String)file::load(alloc, f_name)!!;

		sz[] ints = alloc::alloc_array(alloc, sz, 10);
		foreach (i, &n : ints)
		{
			*n = i;
		}
		ints = alloc::realloc_array(alloc, ints, sz, 20);
		foreach (i, &n : ints[10:10])
		{
			*n = i + 10;
		}

		Atomic{sz} line_count;
		Atomic{sz} a_line_count;
		line_count.store(0);
		a_line_count.store(0);

		Splitter splitter = contents.tokenize("\n");
	
		while (try line = splitter.next())
		{
			if (line[0] == 'a')
			{
				a_line_count.add(1);
			}
			line_count.add(1);
		}
	};
}

fn bool is_prime(int x)
{
    if (x < 2) return false;
    for (int i = 2; i < x; ++i)
    {
        if (x % i == 0)
		{
            return false;
		}
    }
    return true;
}

fn int next_prime(int x)
{
    for (; !is_prime(x); ++x)
	{}
    return x;
}

fn void task_computation(TaskData task) 
{
	int start = *(int*)task.data;
	int next_p = next_prime(start);
}

const String[*] FILE_NAMES = {
	"resources/input0.txt",
	"resources/input1.txt",
	"resources/input2.txt",
	"resources/input3.txt",
	"resources/input4.txt",
	"resources/input5.txt",
	"resources/input6.txt",
};

fn void general() @test
{
	ThreadArena thread_alloc;
	thread_alloc.init(mem, 1ull << 32);

	ThreadPool{8, 4} pool;
	pool.init()!!;

	defer {
		pool.stop_and_destroy();
		thread_alloc.free();
	}

	const TASK_COUNT = 100;

	ThreadTask[TASK_COUNT] compute_tasks;
	int[TASK_COUNT] primes; 
	
	foreach (int i, &p : primes)
	{
		*p = i*i*i;
	}

	foreach (i, &task : compute_tasks)
	{
		task.func = &task_computation;
		task.data = (void*)&primes[i];
		task.alloc = &thread_alloc;
		task.priority = HIGH;
	}

	ThreadTask[TASK_COUNT] io_tasks;
	String f_name = "input.txt";
	
	foreach (i, &task : io_tasks)
	{
		task.func = &task_background;
		task.data = (void*)&FILE_NAMES[random::rand(FILE_NAMES.len)];
		task.alloc = &thread_alloc;
		task.priority = HIGH;
	}

	pool.submit_task_many(io_tasks[..]);
	pool.submit_task_many(compute_tasks[..]);
}
