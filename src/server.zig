const std = @import("std");
const net = std.net;

const PORT = 1234;

var clients_mutex = std.Thread.Mutex{};
var clients: std.ArrayList(*Client) = undefined;

const Client = struct {
    client: std.net.Server.Connection,
    pool: *std.Thread.Pool,
    allocator: std.mem.Allocator,

    /// Acts as listen, blocks until connection and starts thread for further messages
    pub fn pool_init(self: *Client) !void {
        {
            clients_mutex.lock();
            defer clients_mutex.unlock();
            try clients.append(self);
        }
        try self.pool.spawn(Client.reader, .{self});
    }

    pub fn broadcast_message(_: *Client, message: []const u8) !void {
        clients_mutex.lock();
        defer clients_mutex.unlock();

        var i: usize = 0;
        while (i < clients.items.len) {
            const client = clients.items[i];
            client.client.stream.writer().writeAll(message) catch |err| {
                switch (err) {
                    error.BrokenPipe => {
                        // Client disconnected, remove it from the list
                        _ = clients.orderedRemove(i);
                        continue; // Don't increment i since we removed an element
                    },
                    else => {
                        _ = clients.orderedRemove(i);
                        std.debug.print("Failed to write to client: {}\n", .{err});
                        continue; // Don't increment i since we removed an element
                    },
                }
            };
            i += 1; // Only increment if we successfully processed this client
        }
    }

    pub fn reader(self: *Client) void {
        defer {
            // Remove self from clients list
            clients_mutex.lock();
            defer clients_mutex.unlock();
            for (clients.items, 0..) |client, i| {
                if (client == self) {
                    _ = clients.orderedRemove(i);
                    break;
                }
            }

            self.client.stream.close();
            self.allocator.destroy(self);
        }
        // NOTE: readAllAllocMem will not block the thread, no documentation :(
        var buffer: [65536]u8 = undefined; // no checks on passing buffer limit, ArrayList
        while (true) {
            const bytes_read = self.client.stream.reader().read(&buffer) catch |err|
                switch (err) {
                    error.ConnectionResetByPeer => {
                        std.debug.print("Client disconnected\n", .{});
                        break;
                    },
                    else => {
                        std.debug.print("Error reading from client: {}\n", .{err});
                        break;
                    },
                };

            if (bytes_read == 0) return;

            std.debug.assert(bytes_read < 65536);
            // Process the message
            const message = buffer[0..bytes_read];
            if (message.len > 0) {
                std.debug.print("Client says: {s}\n", .{message});
            }

            // Broadcast message to all clients
            const response = std.fmt.allocPrint(self.allocator, "Received at {d}: {s}", .{ std.time.timestamp(), message }) catch |err| {
                std.debug.print("Error creating response: {}\n", .{err});
                continue;
            };
            defer self.allocator.free(response);

            self.broadcast_message(response) catch |err| {
                std.debug.print("Error broadcasting message: {}\n", .{err});
            };
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // TODO: Investigate how this works: https://noelmrtn.fr/posts/zig_threading/
    // Allocator for pool
    var single_threaded_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer single_threaded_arena.deinit();
    var thread_safe_arena: std.heap.ThreadSafeAllocator = .{
        .child_allocator = single_threaded_arena.allocator(),
    };
    const arena = thread_safe_arena.allocator();

    const Pool = std.Thread.Pool;
    var thread_pool: Pool = undefined;
    try thread_pool.init(Pool.Options{
        .allocator = arena, // this is an arena allocator from `std.heap.ArenaAllocator`
        .n_jobs = 256, // this sets the max amount of clients that can join
    });
    defer thread_pool.deinit();
    defer {
        for (0..clients.items.len) |i| {
            // No need to shift elements if all are removed
            _ = clients.swapRemove(i);
        }
    }

    clients = std.ArrayList(*Client).init(gpa.allocator());
    defer clients.deinit();

    clients_mutex = std.Thread.Mutex{};

    const loopback = try net.Ip4Address.parse("127.0.0.1", PORT);
    const localhost = net.Address{ .in = loopback };
    var server = try localhost.listen(.{
        .reuse_port = true,
    });
    defer server.deinit();

    const addr = server.listen_address;
    std.debug.print("Listening on {}, access this port to end the program\n", .{addr.getPort()});

    // Start listening for connections and adding to thread pool
    while (true) {
        const temp_client = try server.accept(); // blocks
        // Allocate Client on heap
        var client = try gpa.allocator().create(Client);
        client.* = Client{
            .client = temp_client,
            .pool = &thread_pool,
            .allocator = gpa.allocator(),
        };
        try client.pool_init();
        // TODO: Figure out how to deinit all threads in a pool
    }
}
