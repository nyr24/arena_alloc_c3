module thread_pool_test;

import data_structures::thread_pool;
import custom_allocators::arena;

import std::time;
import std::math;
import std::io;
import std::atomic;

fn void task_background(TaskData task) 
{
	String f_name = *(String*)task.arg;

	Arena* arena = (Arena*)task.alloc;

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

		io::printfn("ints: %s", ints[..]);
	
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

		io::printfn("IO task finished, line count: %d %d", line_count.load(), a_line_count.load());
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
	int start = *(int*)task.arg;
	int next_p = next_prime(start);

	io::printfn("COMPUTE task finished, next prime from: %s is: %s", start, next_p);
}

fn void thread_pool_test() @test
{
	Arena thread_alloc;
	thread_alloc.init(mem, 1ull << 32);

	ThreadPool{8, 1} pool;
	pool.init()!!;

	defer {
		pool.stop_and_destroy();
		io::printn(thread_alloc);
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
		task.arg = (void*)&primes[i];
		task.alloc = &thread_alloc;
		task.priority = HIGH;
	}

	ThreadTask[TASK_COUNT] io_tasks;
	String f_name = "input.txt";
	
	foreach (i, &task : io_tasks)
	{
		task.func = &task_background;
		task.arg = (void*)&f_name;
		task.alloc = &thread_alloc;
		task.priority = HIGH;
	}

	pool.submit_task_many(io_tasks[..]);
	pool.submit_task_many(compute_tasks[..]);
}
