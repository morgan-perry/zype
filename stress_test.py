import asyncio
import os
import threading
import time

import psutil


class Stats:
    def __init__(self):
        self.request_count = 0
        self.total_requests = 0
        self.active_clients = 0
        self.lock = threading.Lock()

    def increment_requests(self, count=1):
        with self.lock:
            self.request_count += count
            self.total_requests += count

    def get_and_reset_requests(self):
        with self.lock:
            count = self.request_count
            self.request_count = 0
            return count

async def client(client_id, stats, request_rate):
    try:
        reader, writer = await asyncio.open_connection('localhost', 1234)
        stats.active_clients += 1
        message = f"Client {client_id}: ping\n".encode()
        
        while True:
            start_time = time.time()
            
            # Send burst of requests
            for _ in range(request_rate):
                writer.write(message)
            await writer.drain()
            
            stats.increment_requests(request_rate)
            
            # Sleep for remaining time if any
            elapsed = time.time() - start_time
            if elapsed < 1:
                await asyncio.sleep(1 - elapsed)
                
    except Exception as e:
        print(f"Client {client_id} error: {e}")
    finally:
        writer.close()
        await writer.wait_closed()
        stats.active_clients -= 1

def get_process_cpu():
    process = psutil.Process(os.getpid())
    return process.cpu_percent()

def stats_reporter(stats):
    last_time = time.time()
    while True:
        time.sleep(1)
        current_time = time.time()
        elapsed = current_time - last_time
        requests = stats.get_and_reset_requests()
        rps = requests / elapsed
        python_cpu = get_process_cpu()
        
        # Get Zig server CPU usage (adjust the process name as needed)
        zig_cpu = 0
        for proc in psutil.process_iter(['name', 'cpu_percent']):
            if proc.info['name'] == 'zig build s':  # Replace with your Zig server process name
                zig_cpu = proc.info['cpu_percent']
                break
                
        print(f"Active Clients: {stats.active_clients}, "
              f"Requests/sec: {rps:.2f}, "
              f"Total Requests: {stats.total_requests}, "
              f"Python CPU: {python_cpu}%, "
              f"Zig CPU: {zig_cpu}%")
        last_time = current_time

async def main():
    stats = Stats()
    NUM_CLIENTS = 50
    initial_requests_per_sec = 1000
    
    # Start stats reporter
    stats_thread = threading.Thread(target=stats_reporter, args=(stats,))
    stats_thread.daemon = True
    stats_thread.start()

    try:
        requests_per_sec = initial_requests_per_sec
        while True:
            # Create clients
            clients = [client(i, stats, requests_per_sec) 
                      for i in range(NUM_CLIENTS)]
            
            # Run clients concurrently
            await asyncio.gather(*clients)
            
            await asyncio.sleep(5)
            requests_per_sec *= 2

    except KeyboardInterrupt:
        print("\nShutting down...")

if __name__ == "__main__":
    asyncio.run(main())
