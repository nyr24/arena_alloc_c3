module data_structures::thread_pool;

import std::thread;

<*
 User should fill this structure to submit a task.
*>
struct ThreadTask
{
	inline ThreadTaskPrivate _task;
	TaskPriority priority;
}

<*
 Passed into the task as argument.
 Accessed by user code.
*>
struct TaskData
{
	void* data;
	Allocator alloc;
}

<*
 Used internally to store a task.
*>
struct ThreadTaskPrivate @private
{
	ThreadFn func;
	void* data;
	Allocator alloc;
}

<*
 Collects all the data pool needs for synchronization.
 Only for internal use.
*>
struct PoolData @private
{
	Mutex mutex;
	ConditionVariable cond_task_acquired;
	ConditionVariable cond_task_finished;
	ConditionVariable cond_collect;
	bitstruct : sz
	{
		bool initialized : 0..0;
		bool stop : 1..1;
		bool stop_now : 2..2;
		bool joining : 3..3;
		sz busy_thread_count : 4..(bitsizeof(sz) - 1);
	}
}

<*
 Task priority.
 LOW - For IO / background tasks.
 HIGH - For computation-intensive, urgent tasks.
*>
enum TaskPriority : (ThreadPriority thread_prio)
{
	// For IO / background tasks.
	LOW  { DEFAULT  },
	// For computation-intensive, urgent tasks.
	HIGH { REALTIME },
}

alias ThreadFn = fn void(TaskData task_data);

module data_structures::thread_pool <HIGH_CAP, LOW_CAP>;
import std::thread;
import std::collections::ringbuffer;

<*
 Thread pool root structure which manages 2 separate pools: high priority, and low priority.
*>
struct ThreadPool
{
	PoolData high_pool;
	PoolData low_pool;
	RingBuffer{ThreadTaskPrivate, HIGH_CAP} high_queue;
	RingBuffer{ThreadTaskPrivate, LOW_CAP} low_queue;
	Thread[HIGH_CAP] high_threads;
	Thread[LOW_CAP] low_threads;
}

<*
 @require !self.is_initialized() : "Pools must not be already initialized"
*>
fn void? ThreadPool.init(&self, sz stack_size_low = 0, sz stack_size_high = 0)
{
	defer catch self.destroy();

	PoolData* pool = &self.high_pool;
	*pool = { .busy_thread_count = HIGH_CAP, .initialized = true };
	pool.mutex.init()!;
	pool.cond_task_acquired.init()!;
	pool.cond_task_finished.init()!;
	pool.cond_collect.init()!;

	pool = &self.low_pool;
	*pool = { .busy_thread_count = LOW_CAP, .initialized = true };
	pool.mutex.init()!;
	pool.cond_task_acquired.init()!;
	pool.cond_task_finished.init()!;
	pool.cond_collect.init()!;

	self.high_queue.init();
	self.low_queue.init();
	
	foreach (&thread : self.high_threads)
	{
		thread.create(&process_high_prio_task, self, { stack_size_high, TaskPriority.HIGH.thread_prio })!;
		// The thread resources will be cleaned up when the thread exits.
		thread.detach()!;
	}
	
	foreach (&thread : self.low_threads)
	{
		thread.create(&process_low_prio_task, self, { stack_size_low, TaskPriority.LOW.thread_prio })!;
		// The thread resources will be cleaned up when the thread exits.
		thread.detach()!;
	}
}

<*
 Join all threads in the pool.

 @require self.high_pool.initialized : "Must be initialzied"
 @require self.low_pool.initialized : "Must be initialzied"
*>
fn void ThreadPool.join_all(&self)
{
	PoolData* pool = &self.high_pool;

	while (pool.busy_thread_count > 0)
	{
		pool.mutex.lock();
		pool.joining = true;
		pool.cond_task_acquired.broadcast();
		pool.cond_collect.wait(&pool.mutex);
		pool.joining = false;
		pool.mutex.unlock();
	}

	pool = &self.low_pool;
	
	while (pool.busy_thread_count > 0)
	{
		pool.mutex.lock();
		pool.joining = true;
		pool.cond_task_acquired.broadcast();
		pool.cond_collect.wait(&pool.mutex);
		pool.joining = false;
		pool.mutex.unlock();
	}
}

<*
 Join all threads with certain priority in the pool.
*>
fn void ThreadPool.join_by_priority(&self, TaskPriority priority)
{
	PoolData* pool = &((PoolData*)&self.high_pool)[priority];
	assert(pool.initialized, "Must be initialized");

	while (pool.busy_thread_count > 0)
	{
		pool.mutex.lock();
		pool.joining = true;
		pool.cond_task_acquired.broadcast();
		pool.cond_collect.wait(&pool.mutex);
		pool.joining = false;
		pool.mutex.unlock();
	}
}

<*
 Submits a new task to the pool.
*>
fn void ThreadPool.submit_task(&self, ThreadTask task)
{
	if (task.priority == LOW)
	{
		PoolData* pool = &self.low_pool;
		pool.mutex.lock();
		defer pool.mutex.unlock();

		while (true)
		{
			if (!self.low_queue.is_full())
			{
				self.low_queue.push(task);
				// cond_task_acquired the thread that work is available.
				pool.cond_task_acquired.signal();
				return;
			}
			pool.cond_task_finished.wait(&pool.mutex);
		}
	}
	else
	{
		PoolData* pool = &self.high_pool;
		pool.mutex.lock();
		defer pool.mutex.unlock();

		while (true)
		{
			if (!self.high_queue.is_full())
			{
				self.high_queue.push(task);
				// cond_task_acquired the thread that work is available.
				pool.cond_task_acquired.signal();
				return;
			}
			pool.cond_task_finished.wait(&pool.mutex);
		}
	}
}

<*
 Submits multiple tasks to the pool.
*>
fn void ThreadPool.submit_task_many(&self, ThreadTask[] tasks)
{
	foreach (j : tasks)
	{
		self.submit_task(j);
	}
}

<*
 Internal procedure for running high-priority threads.
*>
fn int process_high_prio_task(void* arg) @local
{
	ThreadPool* self = (ThreadPool*)arg;
	PoolData* pool = &self.high_pool;

	while (true)
	{
		pool.mutex.lock();
		// Wait for work.
		while (self.high_queue.is_empty())
		{
			if (pool.joining) pool.cond_collect.broadcast();
			if (pool.stop)
			{
				// Shutdown requested.
				pool.busy_thread_count--;
				pool.mutex.unlock();
				return 0;
			}
			pool.cond_task_acquired.wait(&pool.mutex);
			if (pool.stop_now)
			{
				// Shutdown requested.
				pool.busy_thread_count--;
				pool.mutex.unlock();
				return 0;
			}
		}
		ThreadTaskPrivate task = self.high_queue.pop_first()!!;
		pool.mutex.unlock();
		// Process the task.
		task.func((TaskData){ task.data, task.alloc });
		pool.cond_task_finished.broadcast();
	}
}

<*
 Internal procedure for running low-priority threads.
*>
fn int process_low_prio_task(void* arg) @local
{
	ThreadPool* self = arg;
	PoolData* pool = &self.low_pool;

	// NOTE: TEMP
	@pool_init(mem, 1 << 30)
	{
		while (true)
		{
			pool.mutex.lock();
			// Wait for work.
			while (self.low_queue.is_empty())
			{
				if (pool.joining) pool.cond_collect.broadcast();
				if (pool.stop)
				{
					// Shutdown requested.
					pool.busy_thread_count--;
					pool.mutex.unlock();
					return 0;
				}
				pool.cond_task_acquired.wait(&pool.mutex);
				if (pool.stop_now)
				{
					// Shutdown requested.
					pool.busy_thread_count--;
					pool.mutex.unlock();
					return 0;
				}
			}
			ThreadTaskPrivate task = self.low_queue.pop_first()!!;
			pool.mutex.unlock();
			// Process the task.
			task.func((TaskData){ task.data, task.alloc });
			pool.cond_task_finished.broadcast();
		}
	};
}


<*
 Stop all the threads and cleanup the pool.
 Any pending work will be dropped.
*>
fn void ThreadPool.destroy(&self)
{
	@shutdown(self.high_pool, self.high_pool.stop_now);
	@shutdown(self.low_pool, self.low_pool.stop_now);
}

<*
 Tells if subpools are initialized.
*>
fn bool ThreadPool.is_initialized(&self)
{
	return self.high_pool.initialized && self.low_pool.initialized;
}

<*
 Stop all the threads and cleanup the pool.
 Any pending work will be processed.
*>
fn void ThreadPool.stop_and_destroy(&self)
{
	@shutdown(self.high_pool, self.high_pool.stop);
	@shutdown(self.low_pool, self.low_pool.stop);
}

macro void @shutdown(PoolData #pool, #stop) @local
{
	if (#pool.initialized)
	{
		#pool.mutex.lock();
		#stop = true;
		#pool.cond_task_acquired.broadcast();
		#pool.mutex.unlock();
		// Wait for all threads to shutdown.
		while (true)
		{
			#pool.mutex.lock();
			defer #pool.mutex.unlock();
			if (#pool.busy_thread_count == 0)
			{
				break;
			}
			#pool.cond_task_acquired.signal();
		}
		#pool.mutex.destroy();
		#pool.cond_task_acquired.destroy();
		#pool.cond_task_finished.destroy();
		#pool.cond_collect.destroy();
		#pool.initialized = false;
	}
}
