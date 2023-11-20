const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const graphics = main.graphics;
const draw = graphics.draw;
const Texture = graphics.Texture;
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const GuiComponent = gui.GuiComponent;

pub var window = GuiWindow {
	.relativePosition = .{
		.{ .attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower} },
		.{ .attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower} },
	},
	.contentSize = Vec2f{128, 16},
	.id = "debug",
	.isHud = false,
	.showTitleBar = false,
	.hasBackground = false,
	.hideIfMouseIsGrabbed = false,
};

fn flawedRender() !void {
	draw.setColor(0xffffffff);
	var y: f32 = 0;
	try draw.print("    fps: {d:.0} Hz{s}", .{1.0/main.lastFrameTime.load(.Monotonic), if(main.settings.vsync) @as([]const u8, " (vsync)") else ""}, 0, y, 8, .left);
	y += 8;
	try draw.print("    frameTime: {d:.1} ms", .{main.lastFrameTime.load(.Monotonic)*1000.0}, 0, y, 8, .left);
	y += 8;
	try draw.print("window size: {}×{}", .{main.Window.width, main.Window.height}, 0, y, 8, .left);
	y += 8;
	if (main.game.world != null) {
		try draw.print("Pos: {d:.1}", .{main.game.Player.getPosBlocking()}, 0, y, 8, .left);
		y += 8;
		try draw.print("Game Time: {}", .{main.game.world.?.gameTime.load(.Monotonic)}, 0, y, 8, .left);
		y += 8;
		try draw.print("Queue size: {}", .{main.threadPool.queueSize()}, 0, y, 8, .left);
		y += 8;
		const faceDataSize = @sizeOf(main.chunk.meshing.FaceData);
		try draw.print("Chunk Face memory: {} MiB / {} MiB (fragmentation: {})", .{main.chunk.meshing.faceBuffer.used*faceDataSize >> 20, main.chunk.meshing.faceBuffer.capacity*faceDataSize >> 20, main.chunk.meshing.faceBuffer.freeBlocks.items.len}, 0, y, 8, .left);
		y += 8;
		const chunkDataSize = @sizeOf(main.chunk.meshing.ChunkData);
		try draw.print("Chunk memory: {} MiB / {} MiB (fragmentation: {})", .{main.chunk.meshing.chunkBuffer.used*chunkDataSize >> 20, main.chunk.meshing.chunkBuffer.capacity*chunkDataSize >> 20, main.chunk.meshing.chunkBuffer.freeBlocks.items.len}, 0, y, 8, .left);
		y += 8;
		const lightDataSize = @sizeOf(main.chunk.meshing.LightData);
		try draw.print("Chunk light memory: {} MiB / {} MiB (fragmentation: {})", .{main.chunk.meshing.lightBuffer.used*lightDataSize >> 20, main.chunk.meshing.lightBuffer.capacity*lightDataSize >> 20, main.chunk.meshing.lightBuffer.freeBlocks.items.len}, 0, y, 8, .left);
		y += 8;
		try draw.print("Biome: {s}", .{main.game.world.?.playerBiome.load(.Monotonic).id}, 0, y, 8, .left);
		y += 8;
		try draw.print("Opaque faces: {}, Transparent faces: {}", .{main.chunk.meshing.quadsDrawn, main.chunk.meshing.transparentQuadsDrawn}, 0, y, 8, .left);
		y += 8;
		// TODO: packet loss
		// TODO: Protocol statistics(maybe?)
	}
}

pub fn render() Allocator.Error!void {
	flawedRender() catch |err| {
		std.log.err("Encountered error while drawing debug window: {s}", .{@errorName(err)});
	};
}