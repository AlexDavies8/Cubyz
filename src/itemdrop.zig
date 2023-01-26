const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk_zig = @import("chunk.zig");
const Chunk = chunk_zig.Chunk;
const game = @import("game.zig");
const World = game.World;
const graphics = @import("graphics.zig");
const c = graphics.c;
const items = @import("items.zig");
const ItemStack = items.ItemStack;
const JsonElement = @import("json.zig").JsonElement;
const main = @import("main.zig");
const random = @import("random.zig");
const settings = @import("settings.zig");
const utils = @import("utils.zig");
const vec = @import("vec.zig");
const Mat4f = vec.Mat4f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;

const ItemDrop = struct {
	pos: Vec3d,
	vel: Vec3d,
	rot: Vec3f,
	itemStack: ItemStack,
	despawnTime: u32,
	pickupCooldown: u32,

	reverseIndex: u16,
};

pub const ItemDropManager = struct {
	/// Half the side length of all item entities hitboxes as a cube.
	const radius: f64 = 0.1;
	/// Side length of all item entities hitboxes as a cube.
	const diameter: f64 = 2*radius;

	const pickupRange: f64 = 1.0;

	const maxSpeed = 10;

	const maxCapacity = 65536;

	allocator: Allocator,

	mutex: std.Thread.Mutex = std.Thread.Mutex{},

	list: std.MultiArrayList(ItemDrop),

	indices: [maxCapacity]u16 = undefined,

	isEmpty: std.bit_set.ArrayBitSet(usize, maxCapacity),

	world: *World,
	gravity: f64,
	airDragFactor: f64,

	size: u32 = 0,

	lastUpdates: JsonElement,

	// TODO: Get rid of this inheritance pattern.
	addWithIndexAndRotation: *const fn(*ItemDropManager, u16, Vec3d, Vec3d, Vec3f, ItemStack, u32, u32) void,

	pub fn init(self: *ItemDropManager, allocator: Allocator, world: *World) !void {
		self.* = ItemDropManager {
			.allocator = allocator,
			.list = std.MultiArrayList(ItemDrop){},
			.lastUpdates = try JsonElement.initArray(allocator),
			.isEmpty = std.bit_set.ArrayBitSet(usize, maxCapacity).initFull(),
			.world = world,
			.gravity = world.gravity,
			.airDragFactor = world.gravity/maxSpeed,
			.addWithIndexAndRotation = &defaultAddWithIndexAndRotation,
		};
		try self.list.resize(self.allocator, maxCapacity);
	}

	pub fn deinit(self: *ItemDropManager) void {
		for(self.indices[0..self.size]) |i| {
			if(self.list.items(.itemStack)[i].item) |item| {
				item.deinit();
			}
		}
		self.list.deinit(self.allocator);
		self.lastUpdates.free(self.allocator);
	}

	pub fn loadFrom(self: *ItemDropManager, json: JsonElement) !void {
		const jsonArray = json.getChild("array");
		for(jsonArray.toSlice()) |elem| {
			try self.addFromJson(elem);
		}
	}

	pub fn addFromJson(self: *ItemDropManager, json: JsonElement) !void {
		const item = try items.Item.init(json);
		const properties = .{
			Vec3d{
				json.get(f64, "x", 0),
				json.get(f64, "y", 0),
				json.get(f64, "z", 0),
			},
			Vec3d{
				json.get(f64, "vx", 0),
				json.get(f64, "vy", 0),
				json.get(f64, "vz", 0),
			},
			items.ItemStack{.item = item, .amount = json.get(u16, "amount", 1)},
			json.get(u32, "despawnTime", 60),
			0
		};
		if(json.get(?usize, "i", null)) |i| {
			@call(.auto, addWithIndex, .{self, @intCast(u16, i)} ++ properties);
		} else {
			try @call(.auto, add, .{self} ++ properties);
		}
	}

	pub fn getPositionAndVelocityData(self: *ItemDropManager, allocator: Allocator) ![]u8 {
		const _data = try allocator.alloc(u8, self.size*50);
		var data = _data;
		var ii: u16 = 0;
		while(data.len != 0): (ii += 1) {
			const i = self.indices[ii];
			std.mem.writeIntBig(u16, data[0..2], i);
			std.mem.writeIntBig(u64, data[2..10], @bitCast(u64, self.pos[i][0]));
			std.mem.writeIntBig(u64, data[10..18], @bitCast(u64, self.pos[i][1]));
			std.mem.writeIntBig(u64, data[18..26], @bitCast(u64, self.pos[i][2]));
			std.mem.writeIntBig(u64, data[26..34], @bitCast(u64, self.vel[i][0]));
			std.mem.writeIntBig(u64, data[34..42], @bitCast(u64, self.vel[i][1]));
			std.mem.writeIntBig(u64, data[42..50], @bitCast(u64, self.vel[i][2]));
			data = data[50..];
		}
		return _data;
	}

	fn storeSingle(self: *ItemDropManager, allocator: Allocator, i: u16) !JsonElement {
		std.debug.assert(!self.mutex.tryLock()); // Mutex must be locked!
		var obj = try JsonElement.initObject(allocator);
		const itemDrop = self.list.get(i);
		try obj.put("i", i);
		try obj.put("x", itemDrop.pos.x);
		try obj.put("y", itemDrop.pos.y);
		try obj.put("z", itemDrop.pos.z);
		try obj.put("vx", itemDrop.vel.x);
		try obj.put("vy", itemDrop.vel.y);
		try obj.put("vz", itemDrop.vel.z);
		try itemDrop.itemStack.storeToJson(obj);
		try obj.put("despawnTime", itemDrop.despawnTime);
		return obj;
	}

	pub fn store(self: *ItemDropManager, allocator: Allocator) !JsonElement {
		const jsonArray = try JsonElement.initArray(allocator);
		{
			self.mutex.lock();
			defer self.mutex.unlock();
			var ii: u32 = 0;
			while(ii < self.size) : (ii += 1) {
				const item = try self.storeSingle(allocator, self.indices[ii]);
				try jsonArray.JsonArray.append(item);
			}
		}
		const json = try JsonElement.initObject(allocator);
		json.put("array", jsonArray);
		return json;
	}

	pub fn update(self: *ItemDropManager, deltaTime: f32) void {
		const pos = self.list.items(.pos);
		const vel = self.list.items(.vel);
		const pickupCooldown = self.list.items(.pickupCooldown);
		const despawnTime = self.list.items(.despawnTime);
		var ii: u32 = 0;
		while(ii < self.size) : (ii += 1) {
			const i = self.indices[ii];
			if(self.world.getChunk(pos[i][0], pos[i][1], pos[i][2])) |chunk| {
				// Check collision with blocks:
				self.updateEnt(chunk, &pos[i], &vel[i], deltaTime);
			}
			pickupCooldown[i] -= 1;
			despawnTime[i] -= 1;
			if(despawnTime[i] < 0) {
				self.remove(i);
				ii -= 1;
			}
		}
	}

//TODO:
//	public void checkEntity(Entity ent) {
//		for(int ii = 0; ii < size; ii++) {
//			int i = indices[ii] & 0xffff;
//			int i3 = 3*i;
//			if (pickupCooldown[i] >= 0) continue; // Item cannot be picked up yet.
//			if (Math.abs(ent.position.x - posxyz[i3]) < ent.width + PICKUP_RANGE && Math.abs(ent.position.y + ent.height/2 - posxyz[i3 + 1]) < ent.height + PICKUP_RANGE && Math.abs(ent.position.z - posxyz[i3 + 2]) < ent.width + PICKUP_RANGE) {
//				if(ent.getInventory().canCollect(itemStacks[i].getItem())) {
//					if(ent instanceof Player) {
//						// Needs to go through the network.
//						for(User user : Server.users) {
//							if(user.player == ent) {
//								Protocols.GENERIC_UPDATE.itemStackCollect(user, itemStacks[i]);
//								remove(i);
//								ii--;
//								break;
//							}
//						}
//					} else {
//						int newAmount = ent.getInventory().addItem(itemStacks[i].getItem(), itemStacks[i].getAmount());
//						if(newAmount != 0) {
//							itemStacks[i].setAmount(newAmount);
//						} else {
//							remove(i);
//							ii--;
//						}
//					}
//				}
//			}
//		}
//	}

	pub fn addFromBlockPosition(self: *ItemDropManager, blockPos: Vec3i, vel: Vec3d, itemStack: ItemStack, despawnTime: u32) void {
		self.add(
			Vec3d {
				@intToFloat(f64, blockPos[0]) + @floatCast(f64, random.nextFloat(&main.seed)), // TODO: Consider block bounding boxes.
				@intToFloat(f64, blockPos[1]) + @floatCast(f64, random.nextFloat(&main.seed)),
				@intToFloat(f64, blockPos[2]) + @floatCast(f64, random.nextFloat(&main.seed)),
			} + @splat(3, @as(f64, radius)),
			vel,
			Vec3f {
				2*std.math.pi*random.nextFloat(&main.seed),
				2*std.math.pi*random.nextFloat(&main.seed),
				2*std.math.pi*random.nextFloat(&main.seed),
			},
			itemStack, despawnTime, 0
		);
	}

	pub fn add(self: *ItemDropManager, pos: Vec3d, vel: Vec3d, itemStack: ItemStack, despawnTime: u32, pickupCooldown: u32) !void {
		try self.addWithRotation(
			pos, vel,
			Vec3f {
				2*std.math.pi*random.nextFloat(&main.seed),
				2*std.math.pi*random.nextFloat(&main.seed),
				2*std.math.pi*random.nextFloat(&main.seed),
			},
			itemStack, despawnTime, pickupCooldown
		);
	}
	
	pub fn addWithIndex(self: *ItemDropManager, i: u16, pos: Vec3d, vel: Vec3d, itemStack: ItemStack, despawnTime: u32, pickupCooldown: u32) void {
		self.addWithIndexAndRotation(
			self, i, pos, vel,
			Vec3f {
				2*std.math.pi*random.nextFloat(&main.seed),
				2*std.math.pi*random.nextFloat(&main.seed),
				2*std.math.pi*random.nextFloat(&main.seed),
			},
			itemStack, despawnTime, pickupCooldown
		);
	}

	pub fn addWithRotation(self: *ItemDropManager, pos: Vec3d, vel: Vec3d, rot: Vec3f, itemStack: ItemStack, despawnTime: u32, pickupCooldown: u32) !void {
		var i: u16 = undefined;
		{
			self.mutex.lock();
			defer self.mutex.unlock();
			if(self.size == maxCapacity) {
				const json = try itemStack.store(main.threadAllocator);
				defer json.free(main.threadAllocator);
				const string = try json.toString(main.threadAllocator);
				defer main.threadAllocator.free(string);
				std.log.err("Item drop capacitiy limit reached. Failed to add itemStack: {s}", .{string});
				if(itemStack.item) |item| {
					item.deinit();
				}
				return;
			}
			i = @intCast(u16, self.isEmpty.findFirstSet().?);
		}
		self.addWithIndexAndRotation(self, i, pos, vel, rot, itemStack, despawnTime, pickupCooldown);
	}

	fn defaultAddWithIndexAndRotation(self: *ItemDropManager, i: u16, pos: Vec3d, vel: Vec3d, rot: Vec3f, itemStack: ItemStack, despawnTime: u32, pickupCooldown: u32) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		std.debug.assert(self.isEmpty.isSet(i));
		self.isEmpty.unset(i);
		self.list.set(i, ItemDrop {
			.pos = pos,
			.vel = vel,
			.rot = rot,
			.itemStack = itemStack,
			.despawnTime = despawnTime,
			.pickupCooldown = pickupCooldown,
			.reverseIndex = @intCast(u16, self.size),
		});
// TODO:
//			if(world instanceof ServerWorld) {
//				lastUpdates.add(storeSingle(i));
//			}
		self.indices[self.size] = i;
		self.size += 1;
	}

	pub fn remove(self: *ItemDropManager, i: u16) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		self.size -= 1;
		const ii = self.list.items(.reverseIndex)[i];
		self.indices[ii] = self.indices[self.size];
		self.list.items(.itemStack)[i].clear();
		self.isEmpty.set(i);
		// TODO:
//			if(world instanceof ServerWorld) {
//				lastUpdates.add(new JsonInt(i));
//			}
	}
// TODO: Check if/how this is needed:
//	public Vector3d getPosition(int index) {
//		index *= 3;
//		return new Vector3d(posxyz[index], posxyz[index+1], posxyz[index+2]);
//	}
//
//	public Vector3f getRotation(int index) {
//		index *= 3;
//		return new Vector3f(rotxyz[index], rotxyz[index+1], rotxyz[index+2]);
//	}

	fn updateEnt(self: *ItemDropManager, chunk: *Chunk, pos: *Vec3d, vel: *Vec3d, deltaTime: f64) void {
		std.debug.assert(!self.mutex.tryLock()); // Mutex must be locked!
		const startedInABlock = checkBlocks(chunk, pos);
		if(startedInABlock) {
			self.fixStuckInBlock(chunk, pos, vel, deltaTime);
			return;
		}
		const drag: f64 = self.airDragFactor;
		var acceleration: Vec3f = Vec3f{0, -self.gravity*deltaTime, 0};
		// Update gravity:
		inline for([_]u0{0} ** 3) |_, i| { // TODO: Use the new for loop syntax.
			const old = pos[i];
			pos[i] += vel[i]*deltaTime + acceleration[i]*deltaTime;
			if(self.checkBlocks(chunk, pos)) {
				pos[i] = old;
				vel[i] *= 0.5; // Effectively performing binary search over multiple frames.
			}
			drag += 0.5; // TODO: Calculate drag from block properties and add buoyancy.
		}
		// Apply drag:
		vel.* += acceleration;
		vel.* *= @splat(3, @max(0, 1 - drag*deltaTime));
	}

	fn fixStuckInBlock(self: *ItemDropManager, chunk: *Chunk, pos: *Vec3d, vel: *Vec3d, deltaTime: f64) void {
		std.debug.assert(!self.mutex.tryLock()); // Mutex must be locked!
		const centeredPos = pos.* - @splat(3, @as(f64, 0.5));
		const pos0 = vec.floatToInt(i32, @floor(centeredPos));

		var closestEmptyBlock = @splat(3, @splat(i32, -1));
		var closestDist = std.math.floatMax(f64);
		var delta = Vec3i{0, 0, 0};
		while(delta[0] <= 1) : (delta[0] += 1) {
			delta[1] = 0;
			while(delta[1] <= 1) : (delta[1] += 1) {
				delta[2] = 0;
				while(delta[2] <= 1) : (delta[2] += 1) {
					const isSolid = self.checkBlock(chunk, pos, pos0 + delta);
					if(!isSolid) {
						const dist = vec.lengthSquare(vec.intToFloat(f64, pos0 + delta) - centeredPos);
						if(dist < closestDist) {
							closestDist = dist;
							closestEmptyBlock = delta;
						}
					}
				}
			}
		}

		vel.* = @splat(3, @as(f64, 0));
		const factor = 1; // TODO: Investigate what past me wanted to accomplish here.
		if(closestDist == std.math.floatMax(f64)) {
			// Surrounded by solid blocks → move upwards
			vel[1] = factor;
			pos[1] += vel[1]*deltaTime;
		} else {
			vel.* = @splat(3, factor)*(vec.intToFloat(f64, pos0 + closestEmptyBlock) - centeredPos);
			pos.* += (vel.*)*@splat(3, deltaTime);
		}
	}

	fn checkBlocks(self: *ItemDropManager, chunk: *Chunk, pos: *Vec3d) void {
		const lowerCornerPos = pos.* - @splat(3, radius);
		const pos0 = vec.floatToInt(i32, @floor(lowerCornerPos));
		const isSolid = self.checkBlock(chunk, pos, pos0);
		if(pos[0] - @intToFloat(f64, pos0[0]) + diameter >= 1) {
			isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{1, 0, 0});
			if(pos[1] - @intToFloat(f64, pos0[1]) + diameter >= 1) {
				isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 1, 0});
				isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{1, 0, 0});
				if(pos[2] - @intToFloat(f64, pos0[2]) + diameter >= 1) {
					isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 0, 1});
					isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{1, 0, 1});
					isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 1, 1});
					isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{1, 1, 1});
				}
			} else {
				isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 0, 1});
				isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{1, 0, 1});
			}
		} else {
			if(pos[1] - @intToFloat(f64, pos0[1]) + diameter >= 1) {
				isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 1, 0});
				if(pos[2] - @intToFloat(f64, pos0[2]) + diameter >= 1) {
					isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 0, 1});
					isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 1, 1});
				}
			} else {
				isSolid |= checkBlock(chunk, pos, pos0 + Vec3i{0, 0, 1});
			}
		}
		return isSolid;
	}

	fn checkBlock(self: *ItemDropManager, chunk: *Chunk, pos: *Vec3d, blockPos: Vec3i) bool {
		// TODO:
		_ = self;
		_ = chunk;
		_ = pos;
		_ = blockPos;
		return false;
//		// Transform to chunk-relative coordinates:
//		int block = chunk.getBlockPossiblyOutside(x - chunk.wx, y - chunk.wy, z - chunk.wz);
//		if (block == 0) return false;
//		// Check if the item entity is inside the block:
//		boolean isInside = true;
//		if (Blocks.mode(block).changesHitbox()) {
//			isInside = Blocks.mode(block).checkEntity(new Vector3d(posxyz[index3], posxyz[index3+1]-RADIUS, posxyz[index3+2]), RADIUS, DIAMETER, x, y, z, block);
//		}
//		return isInside && Blocks.solid(block);
	}
};

pub const ClientItemDropManager = struct {
	const maxf64Capacity = ItemDropManager.maxCapacity*@sizeOf(Vec3d)/@sizeOf(f64);

	super: ItemDropManager,

	lastTime: i16,

	timeDifference: utils.TimeDifference = .{},

	interpolation: utils.GenericInterpolation(maxf64Capacity) = undefined,

	var instance: ?*ClientItemDropManager = null;

	pub fn init(self: *ClientItemDropManager, allocator: Allocator, world: *World) !void {
		std.debug.assert(instance == null); // Only one instance allowed.
		instance = self;
		self.* = ClientItemDropManager {
			.super = undefined,
			.lastTime = @truncate(i16, std.time.milliTimestamp()) -% settings.entityLookback,
		};
		try self.super.init(allocator, world);
		self.super.addWithIndexAndRotation = &overrideAddWithIndexAndRotation;
		self.interpolation.init(
			@ptrCast(*[maxf64Capacity]f64, self.super.list.items(.pos).ptr),
			@ptrCast(*[maxf64Capacity]f64, self.super.list.items(.vel).ptr)
		);
	}

	pub fn deinit(self: *ClientItemDropManager) void {
		std.debug.assert(instance != null); // Double deinit.
		instance = null;
		self.super.deinit();
	}

	pub fn readPosition(self: *ClientItemDropManager, _data: []const u8, time: i16) void {
		var data = _data;
		self.timeDifference.addDataPoint(time);
		var pos: [ItemDropManager.maxCapacity]Vec3d = undefined;
		var vel: [ItemDropManager.maxCapacity]Vec3d = undefined;
		while(data.len != 0) {
			const i = std.mem.readIntBig(u16, data[0..2]);
			pos[i][0] = @bitCast(f64, std.mem.readIntBig(u64, data[2..10]));
			pos[i][1] = @bitCast(f64, std.mem.readIntBig(u64, data[10..18]));
			pos[i][2] = @bitCast(f64, std.mem.readIntBig(u64, data[18..26]));
			vel[i][0] = @bitCast(f64, std.mem.readIntBig(u64, data[26..34]));
			vel[i][1] = @bitCast(f64, std.mem.readIntBig(u64, data[34..42]));
			vel[i][2] = @bitCast(f64, std.mem.readIntBig(u64, data[42..50]));
			data = data[50..];
		}
		self.interpolation.updatePosition(@ptrCast(*[maxf64Capacity]f64, &pos), @ptrCast(*[maxf64Capacity]f64, &vel), time); // TODO: Only update the ones we actually changed.
	}

	pub fn updateInterpolationData(self: *ClientItemDropManager) void {
		var time = @truncate(i16, std.time.milliTimestamp()) -% settings.entityLookback;
		time -%= self.timeDifference.difference;
		self.interpolation.updateIndexed(time, self.lastTime, &self.super.indices, 3);
		self.lastTime = time;
	}

	fn overrideAddWithIndexAndRotation(super: *ItemDropManager, i: u16, pos: Vec3d, vel: Vec3d, rot: Vec3f, itemStack: ItemStack, despawnTime: u32, pickupCooldown: u32) void {
		{
			super.mutex.lock();
			defer super.mutex.unlock();
			for(instance.?.interpolation.lastVel) |*lastVel| {
				@ptrCast(*align(8)[ItemDropManager.maxCapacity]Vec3d, lastVel)[i] = Vec3d{0, 0, 0};
			}
			for(instance.?.interpolation.lastPos) |*lastPos| {
				@ptrCast(*align(8)[ItemDropManager.maxCapacity]Vec3d, lastPos)[i] = pos;
			}
		}
		super.defaultAddWithIndexAndRotation(i, pos, vel, rot, itemStack, despawnTime, pickupCooldown);
	}

	pub fn remove(self: *ClientItemDropManager, i: u16) void {
		self.super.remove(i);
	}

	pub fn loadFrom(self: *ClientItemDropManager, json: JsonElement) !void {
		try self.super.loadFrom(json);
	}

	pub fn addFromJson(self: *ClientItemDropManager, json: JsonElement) !void {
		try self.super.addFromJson(json);
	}
};

pub const ItemDropRenderer = struct {
//
//	// uniform locations:
//	private static ShaderProgram shader;
//	public static int loc_projectionMatrix;
//	public static int loc_viewMatrix;
//	public static int loc_texture_sampler;
//	public static int loc_emissionSampler;
//	public static int loc_fog_activ;
//	public static int loc_fog_color;
//	public static int loc_fog_density;
//	public static int loc_ambientLight;
//	public static int loc_directionalLight;
//	public static int loc_light;
//	public static int loc_texPosX;
//	public static int loc_texNegX;
//	public static int loc_texPosY;
//	public static int loc_texNegY;
//	public static int loc_texPosZ;
//	public static int loc_texNegZ;
	var itemShader: graphics.Shader = undefined;
	var itemUniforms: struct {
		projectionMatrix: c_int,
		modelMatrix: c_int,
		viewMatrix: c_int,
		modelPosition: c_int,
		ambientLight: c_int,
		@"fog.activ": c_int,
		@"fog.color": c_int,
		@"fog.density": c_int,
		modelIndex: c_int,
		sizeScale: c_int,
	} = undefined;

	var itemModelSSBO: graphics.SSBO = undefined;
	var itemVAO: c_uint = undefined;
	var itemVBOs: [2]c_uint = undefined;

	var modelData: std.ArrayList(u32) = undefined;
	var freeSlots: std.ArrayList(*ItemVoxelModel) = undefined;

	const ItemVoxelModel = struct {
		index: u31 = undefined,
		size: Vec3i = undefined,
		item: items.Item,

		fn init(template: ItemVoxelModel) !*ItemVoxelModel {
			const self = try main.globalAllocator.create(ItemVoxelModel);
			self.* = ItemVoxelModel{
				.item = template.item,
			};
			// Find sizes and free index:
			const img = self.item.getTexture();
			self.size = Vec3i{img.width, 1, img.height};
			var freeSlot: ?*ItemVoxelModel = null;
			for(freeSlots.items) |potentialSlot, i| {
				if(std.meta.eql(self.size, potentialSlot.size)) {
					freeSlot = potentialSlot;
					_ = freeSlots.swapRemove(i);
					break;
				}
			}
			const modelDataSize: u32 = @intCast(u32, 3 + @reduce(.Mul, self.size));
			var dataSection: []u32 = undefined;
			if(freeSlot) |_freeSlot| {
				main.globalAllocator.destroy(_freeSlot);
				self.index = _freeSlot.index;
			} else {
				self.index = @intCast(u31, modelData.items.len);
				try modelData.resize(self.index + modelDataSize);
			}
			dataSection = modelData.items[self.index..][0..modelDataSize];
			dataSection[0] = @intCast(u32, self.size[0]);
			dataSection[1] = @intCast(u32, self.size[1]);
			dataSection[2] = @intCast(u32, self.size[2]);
			var i: u32 = 3;
			var y: u32 = 0;
			while(y < 1) : (y += 1) {
				var x: u32 = 0;
				while(x < self.size[0]) : (x += 1) {
					var z: u32 = 0;
					while(z < self.size[2]) : (z += 1) {
						dataSection[i] = img.getRGB(x, z).toARBG();
						i += 1;
					}
				}
			}
			itemModelSSBO.bufferData(u32, modelData.items);
			return self;
		}

		fn deinit(self: *ItemVoxelModel) void {
			freeSlots.append(self) catch |err| {
				std.log.err("Encountered error {s} while freeing an ItemVoxelModel. This causes the game to leak {} bytes of memory.", .{@errorName(err), @reduce(.Mul, self.size) + 3});
				main.globalAllocator.destroy(self);
			};
		}

		pub fn equals(self: ItemVoxelModel, other: ?*ItemVoxelModel) bool {
			if(other == null) return false;
			return std.meta.eql(self.item, other.?.item);
		}

		pub fn hashCode(self: ItemVoxelModel) u32 {
			return self.item.hashCode();
		}
	};

	pub fn init() !void {
//		if (shader != null) {
//			shader.cleanup();
//		}
//		shader = new ShaderProgram(Utils.loadResource(shaders + "/block_drop.vs"),
//				Utils.loadResource(shaders + "/block_drop.fs"),
//				BlockDropRenderer.class);
		itemShader = try graphics.Shader.create("assets/cubyz/shaders/item_drop.vs", "assets/cubyz/shaders/item_drop.fs");
		itemUniforms = itemShader.bulkGetUniformLocation(@TypeOf(itemUniforms));
		itemModelSSBO = graphics.SSBO.init();
		itemModelSSBO.bufferData(i32, &[3]i32{1, 1, 1});
		itemModelSSBO.bind(2);

		const positions = [_]i32 {
			0b000,
			0b001,
			0b010,
			0b011,
			0b100,
			0b101,
			0b110,
			0b111,
		};
		const indices = [_]i32 {
			0, 1, 3,
			0, 3, 2,
			0, 5, 1,
			0, 4, 5,
			0, 2, 6,
			0, 6, 4,
			
			4, 7, 5,
			4, 6, 7,
			2, 3, 7,
			2, 7, 6,
			1, 7, 3,
			1, 5, 7,
		};
		c.glGenVertexArrays(1, &itemVAO);
		c.glBindVertexArray(itemVAO);
		c.glEnableVertexAttribArray(0);

		c.glGenBuffers(2, &itemVBOs);
		c.glBindBuffer(c.GL_ARRAY_BUFFER, itemVBOs[0]);
		c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(c_long, positions.len*@sizeOf(i32)), &positions, c.GL_STATIC_DRAW);
		c.glVertexAttribPointer(0, 1, c.GL_FLOAT, c.GL_FALSE, @sizeOf(i32), null);

		c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, itemVBOs[1]);
		c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, @intCast(c_long, indices.len*@sizeOf(i32)), &indices, c.GL_STATIC_DRAW);

		c.glBindVertexArray(0);

		modelData = std.ArrayList(u32).init(main.globalAllocator);
		freeSlots = std.ArrayList(*ItemVoxelModel).init(main.globalAllocator);
	}

	pub fn deinit() void {
		itemShader.delete();
		itemModelSSBO.deinit();
		c.glDeleteVertexArrays(1, &itemVAO);
		c.glDeleteBuffers(2, &itemVBOs);
		modelData.deinit();
		voxelModels.clear();
		for(freeSlots.items) |freeSlot| {
			main.globalAllocator.destroy(freeSlot);
		}
		freeSlots.deinit();
	}

	var voxelModels: utils.Cache(ItemVoxelModel, 32, 32, ItemVoxelModel.deinit) = .{};

	fn getModelIndex(item: items.Item) !u31 {
		const compareObject = ItemVoxelModel{.item = item};
		return (try voxelModels.findOrCreate(compareObject, ItemVoxelModel.init)).index;
	}

	pub fn renderItemDrops(projMatrix: Mat4f, ambientLight: Vec3f, playerPos: Vec3d) !void {
		itemShader.bind();
		c.glUniform1i(itemUniforms.@"fog.activ", if(game.fog.active) 1 else 0);
		c.glUniform3fv(itemUniforms.@"fog.color", 1, @ptrCast([*c]const f32, &game.fog.color));
		c.glUniform1f(itemUniforms.@"fog.density", game.fog.density);
		c.glUniformMatrix4fv(itemUniforms.projectionMatrix, 1, c.GL_FALSE, @ptrCast([*c]const f32, &projMatrix));
		c.glUniform3fv(itemUniforms.ambientLight, 1, @ptrCast([*c]const f32, &ambientLight));
		c.glUniformMatrix4fv(itemUniforms.viewMatrix, 1, c.GL_FALSE, @ptrCast([*c]const f32, &game.camera.viewMatrix));
		c.glUniform1f(itemUniforms.sizeScale, @floatCast(f32, ItemDropManager.diameter/4.0));
		const itemDrops = game.world.?.itemDrops.super;
		for(itemDrops.indices[0..itemDrops.size]) |i| {
			if(itemDrops.list.items(.itemStack)[i].item) |item| {
				var pos = itemDrops.list.items(.pos)[i];
				const rot = itemDrops.list.items(.rot)[i];
				// TODO: lighting:
//				int x = (int)(manager.posxyz[index3] + 1.0f);
//				int y = (int)(manager.posxyz[index3+1] + 1.0f);
//				int z = (int)(manager.posxyz[index3+2] + 1.0f);
//
//				int light = Cubyz.world.getLight(x, y, z, ambientLight, ClientSettings.easyLighting);
				const light: u32 = 0xffffffff;
				c.glUniform3fv(itemUniforms.ambientLight, 1, @ptrCast([*c]const f32, &@max(
					ambientLight*@splat(3, @intToFloat(f32, light >> 24)/255),
					Vec3f{light >> 16 & 255, light >> 8 & 255, light & 255}/@splat(3, @as(f32, 255))
				)));
				pos -= playerPos;
				var modelMatrix = Mat4f.translation(vec.floatCast(f32, pos));
				modelMatrix = modelMatrix.mul(Mat4f.rotationX(-rot[0]));
				modelMatrix = modelMatrix.mul(Mat4f.rotationY(-rot[1]));
				modelMatrix = modelMatrix.mul(Mat4f.rotationZ(-rot[2]));
				c.glUniformMatrix4fv(itemUniforms.modelMatrix, 1, c.GL_FALSE, @ptrCast([*c]const f32, &modelMatrix));
				const index = try getModelIndex(item);
				c.glUniform1i(itemUniforms.modelIndex, index);

				c.glBindVertexArray(itemVAO);
				c.glDrawElements(c.GL_TRIANGLES, 36, c.GL_UNSIGNED_INT, null);
			}
		}
	}
};

//public final class BlockDropRenderer {
//	
//	private static void renderBlockDrops(FrustumIntersection frustumInt, Vector3f ambientLight, DirectionalLight directionalLight, Vector3d playerPosition) {
//		glActiveTexture(GL_TEXTURE0);
//		Meshes.blockTextureArray.bind();
//		glActiveTexture(GL_TEXTURE1);
//		Meshes.emissionTextureArray.bind();
//		shader.bind();
//		shader.setUniform(loc_fog_activ, Cubyz.fog.isActive());
//		shader.setUniform(loc_fog_color, Cubyz.fog.getColor());
//		shader.setUniform(loc_fog_density, Cubyz.fog.getDensity());
//		shader.setUniform(loc_projectionMatrix, Window.getProjectionMatrix());
//		shader.setUniform(loc_texture_sampler, 0);
//		shader.setUniform(loc_emissionSampler, 1);
//		shader.setUniform(loc_ambientLight, ambientLight);
//		shader.setUniform(loc_directionalLight, directionalLight.getDirection());
//		ItemEntityManager manager = Cubyz.world.itemEntityManager;
//		for(int ii = 0; ii < manager.size; ii++) {
//			int i = manager.indices[ii] & 0xffff;
//			if (manager.itemStacks[i].getItem() instanceof ItemBlock) {
//				int index = i;
//				int index3 = 3*i;
//				int x = (int)(manager.posxyz[index3] + 1.0f);
//				int y = (int)(manager.posxyz[index3+1] + 1.0f);
//				int z = (int)(manager.posxyz[index3+2] + 1.0f);
//				int block = ((ItemBlock)manager.itemStacks[i].getItem()).getBlock();
//				Mesh mesh = BlockMeshes.mesh(block & Blocks.TYPE_MASK);
//				mesh.setTexture(null);
//				shader.setUniform(loc_texNegX, BlockMeshes.textureIndices(block)[Neighbors.DIR_NEG_X]);
//				shader.setUniform(loc_texPosX, BlockMeshes.textureIndices(block)[Neighbors.DIR_POS_X]);
//				shader.setUniform(loc_texNegY, BlockMeshes.textureIndices(block)[Neighbors.DIR_DOWN]);
//				shader.setUniform(loc_texPosY, BlockMeshes.textureIndices(block)[Neighbors.DIR_UP]);
//				shader.setUniform(loc_texNegZ, BlockMeshes.textureIndices(block)[Neighbors.DIR_NEG_Z]);
//				shader.setUniform(loc_texPosZ, BlockMeshes.textureIndices(block)[Neighbors.DIR_POS_Z]);
//				if (mesh != null) {
//					shader.setUniform(loc_light, Cubyz.world.getLight(x, y, z, ambientLight, ClientSettings.easyLighting));
//					Vector3d position = manager.getPosition(index).sub(playerPosition);
//					Matrix4f modelMatrix = Transformation.getModelMatrix(new Vector3f((float)position.x, (float)position.y, (float)position.z), manager.getRotation(index), ItemEntityManager.DIAMETER);
//					Matrix4f modelViewMatrix = Transformation.getModelViewMatrix(modelMatrix, Camera.getViewMatrix());
//					shader.setUniform(loc_viewMatrix, modelViewMatrix);
//					glBindVertexArray(mesh.vaoId);
//					mesh.render();
//				}
//			}
//		}
//	}
//	
//	public static void render(FrustumIntersection frustumInt, Vector3f ambientLight, DirectionalLight directionalLight, Vector3d playerPosition) {
//		((InterpolatedItemEntityManager)Cubyz.world.itemEntityManager).updateInterpolationData();
//		renderBlockDrops(frustumInt, ambientLight, directionalLight, playerPosition);
//		renderItemDrops(frustumInt, ambientLight, directionalLight, playerPosition);
//	}
//}