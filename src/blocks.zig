const std = @import("std");

const JsonElement = @import("json.zig").JsonElement;
const Neighbors = @import("chunk.zig").Neighbors;
const SSBO = @import("graphics.zig").SSBO;
const Image = @import("graphics.zig").Image;
const Color = @import("graphics.zig").Color;
const TextureArray = @import("graphics.zig").TextureArray;
const models = @import("models.zig");

pub const BlockClass = enum(u8) {
	wood,
	stone,
	sand,
	unbreakable,
	leaf,
	fluid,
	air
};

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var allocator = arena.allocator();

pub const MaxBLockCount: usize = 65536; // 16 bit limit

pub const BlockDrop = u0; // TODO!
pub const RotationMode = u0; // TODO!

var _lightingTransparent: [MaxBLockCount]bool = undefined;
var _transparent: [MaxBLockCount]bool = undefined;
var _id: [MaxBLockCount][]u8 = undefined;
/// Time in seconds to break this block by hand.
var _hardness: [MaxBLockCount]f32 = undefined;
/// Minimum pickaxe/axe/shovel power required.
var _breakingPower: [MaxBLockCount]f32 = undefined;
var _solid: [MaxBLockCount]bool = undefined;
var _selectable: [MaxBLockCount]bool = undefined;
var _blockDrops: [MaxBLockCount][]BlockDrop = undefined;
/// Meaning undegradable parts of trees or other structures can grow through this block.
var _degradable: [MaxBLockCount]bool = undefined;
var _viewThrough: [MaxBLockCount]bool = undefined;
var _blockClass: [MaxBLockCount]BlockClass = undefined;
var _light: [MaxBLockCount]u32 = undefined;
/// How much light this block absorbs if it is transparent
var _absorption: [MaxBLockCount]u32 = undefined;
/// GUI that is opened on click.
var _gui: [MaxBLockCount][]u8 = undefined;
var _mode: [MaxBLockCount]RotationMode = undefined;

var reverseIndices = std.StringHashMap(u16).init(arena.allocator());

var size: u16 = 0;

pub fn register(_: []const u8, id: []const u8, json: JsonElement) !void {
	if(reverseIndices.contains(id)) {
		std.log.warn("Registered block with id {s} twice!", .{id});
	}
	_id[size] = try allocator.dupe(u8, id);
	try reverseIndices.put(_id[size], size);
//		TODO:
//		_mode[size] = CubyzRegistries.ROTATION_MODE_REGISTRY.getByID(json.getString("rotation", "cubyz:no_rotation"));
//		_blockDrops[size] = new BlockDrop[0];
	_breakingPower[size] = json.get(f32, "breakingPower", 0);
	_hardness[size] = json.get(f32, "hardness", 1);

	var blockClassString = json.get([]const u8, "class", "stone");
	_blockClass[size] = .stone;
	inline for(@typeInfo(BlockClass).Enum.fields) |field| {
		if(std.mem.eql(u8, blockClassString, field.name)) {
			_blockClass[size] = @field(BlockClass, field.name);
		}
	}
	_light[size] = json.get(u32, "emittedLight", 0);
	_absorption[size] = json.get(u32, "absorbedLight", 0);
	_lightingTransparent[size] = json.getChild("absorbedLight") != .JsonNull;
	_degradable[size] = json.get(bool, "degradable", false);
	_selectable[size] = json.get(bool, "selectable", true);
	_solid[size] = json.get(bool, "solid", true);
	_gui[size] = try allocator.dupe(u8, json.get([]const u8, "GUI", ""));
	_transparent[size] = json.get(bool, "transparent", false);
	_viewThrough[size] = json.get(bool, "viewThrough", false) or _transparent[size];

	size += 1;
}

pub fn reset() void {
	size = 0;
	// TODO: Use arena.reset() instead.
	arena.deinit();
	arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	reverseIndices = std.StringHashMap([]const u8).init(arena);
}

pub fn getByID(id: []const u8) u16 {
	if(reverseIndices.get(id)) |result| {
		return result;
	} else {
		std.log.warn("Couldn't find block {s}. Replacing it with air...", .{id});
		return 0;
	}
}

pub const Block = packed struct {
	typ: u16,
	data: u16,
	pub fn toInt(self: Block) u32 {
		return @as(u32, self.typ) | @as(u32, self.data)<<16;
	}
	pub fn fromInt(self: u32) Block {
		return Block{.typ=@truncate(u16, self), .data=@intCast(u16, self>>16)};
	}
	pub fn lightingTransparent(self: Block) bool {
		return _lightingTransparent[self.typ];
	}

	pub fn transparent(self: Block) bool {
		return _transparent[self.typ];
	}

	pub fn id(self: Block) []u8 {
		return _id[self.typ];
	}

	/// Time in seconds to break this block by hand.
	pub fn hardness(self: Block) f32 {
		return _hardness[self.typ];
	}

	/// Minimum pickaxe/axe/shovel power required.
	pub fn breakingPower(self: Block) f32 {
		return _breakingPower[self.typ];
	}

	pub fn solid(self: Block) bool {
		return _solid[self.typ];
	}

	pub fn selectable(self: Block) bool {
		return _selectable[self.typ];
	}

	pub fn blockDrops(self: Block) []BlockDrop {
		return _blockDrops[self.typ];
	}

	/// Meaning undegradable parts of trees or other structures can grow through this block.
	pub fn degradable(self: Block) bool {
		return _degradable[self.typ];
	}

	pub fn viewThrough(self: Block) bool {
		return (&_viewThrough)[self.typ]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
	}

	pub fn blockClass(self: Block) BlockClass {
		return _blockClass[self.typ];
	}

	pub fn light(self: Block) u32 {
		return _light[self.typ];
	}

	/// How much light this block absorbs if it is transparent.
	pub fn absorption(self: Block) u32 {
		return _absorption[self.typ];
	}
	
	/// GUI that is opened on click.
	pub fn gui(self: Block) []u8 {
		return _gui[self.typ];
	}
	
	pub fn mode(self: Block) RotationMode {
		return _mode[self.typ];
	}

//	TODO:
//	/**
//	 * Fires the blocks on click event(usually nothing or GUI opening).
//	 * @param world
//	 * @param pos
//	 * @return if the block did something on click.
//	 */
//	public static boolean onClick(int block, World world, Vector3i pos) {
//		if (gui[block & TYPE_MASK] != null) {
//			GameLauncher.logic.openGUI("cubyz:workbench", new Inventory(26)); // TODO: Care about the inventory.
//			return true;
//		}
//		return false;
//	}
};


pub const meshes = struct {
	const ProceduralMaterial = extern struct {
		const ExternVec3f = [3]f32;
		const MaterialColor = extern struct {
			diffuse: u32,
			emission: u32,
		};
		
		simplex1Wavelength: ExternVec3f,
		simplex1Weight: f32,
		
		simplex2Wavelength: ExternVec3f,
		__padding2: f32,
		simplex2DomainWarp: ExternVec3f,
		simplex2Weight: f32,
		
		simplex3Wavelength: ExternVec3f,
		__padding3: f32,
		simplex3DomainWarp: ExternVec3f,
		simplex3Weight: f32,

		brightnessOffset: f32,

		randomness: f32,

		colors: [8]MaterialColor,

		__paddingTotal: [2]f32,
	};

	const Palette = extern struct {
		materialReference: [8]u32,
	};

	var size: u16 = 0;
	var _modelIndices: [MaxBLockCount]u16 = undefined;
	var _textureIndices: [MaxBLockCount][6]u32 = undefined;
	var palettes: [MaxBLockCount]Palette = undefined;

	var materials: [MaxBLockCount]ProceduralMaterial = undefined;
	var materialSize: u16 = 0;
	var idToMaterial: std.StringHashMap(u16) = undefined;
	/// Stores the number of textures after each block was added. Used to clean additional textures when the world is switched.
	var maxTextureCount: [MaxBLockCount]u32 = undefined;
	/// Number of loaded meshes. Used to determine if an update is needed.
	var loadedMeshes: u32 = 0;

	var arenaForArrayLists: std.heap.ArenaAllocator = undefined;
	var textureIDs: std.ArrayList([]const u8) = undefined;
	var animationFrames: std.ArrayList(u32) = undefined;
	var animationTimes: std.ArrayList(u32) = undefined;
	var blockTextures: std.ArrayList(Image) = undefined;
	var emissionTextures: std.ArrayList(Image) = undefined;

	var arenaForWorld: std.heap.ArenaAllocator = undefined;

	const sideNames = blk: {
		var names: [6][]const u8 = undefined;
		names[Neighbors.dirDown] = "texture_bottom";
		names[Neighbors.dirUp] = "texture_top";
		names[Neighbors.dirPosX] = "texture_right";
		names[Neighbors.dirNegX] = "texture_left";
		names[Neighbors.dirPosZ] = "texture_front";
		names[Neighbors.dirNegZ] = "texture_back";
		break :blk names;
	};

	var animationTimesSSBO: SSBO = undefined;
	var animationFramesSSBO: SSBO = undefined;

	var materialsSSBO: SSBO = undefined;
	var palettesSSBO: SSBO = undefined;

	pub var blockTextureArray: TextureArray = undefined;
	pub var emissionTextureArray: TextureArray = undefined;

	const black: Color = Color{.r=0, .g=0, .b=0, .a=255};
	const magenta: Color = Color{.r=255, .g=0, .b=255, .a=255};
	var undefinedTexture = [_]Color {magenta, black, black, magenta};
	const undefinedImage = Image{.width = 2, .height = 2, .imageData = undefinedTexture[0..]};
	var emptyTexture = [_]Color {black};
	const emptyImage = Image{.width = 1, .height = 1, .imageData = emptyTexture[0..]};

	pub fn init() !void {
		std.log.info("Size: {}", .{@sizeOf(ProceduralMaterial)});
		animationTimesSSBO = SSBO.init();
		animationTimesSSBO.bind(0);
		animationFramesSSBO = SSBO.init();
		animationFramesSSBO.bind(1);
		materialsSSBO = SSBO.init();
		materialsSSBO.bind(5);
		palettesSSBO = SSBO.init();
		palettesSSBO.bind(6);

		blockTextureArray = TextureArray.init();
		emissionTextureArray = TextureArray.init();
		arenaForArrayLists = std.heap.ArenaAllocator.init(std.heap.page_allocator);
		textureIDs = std.ArrayList([]const u8).init(arenaForArrayLists.allocator());
		animationFrames = std.ArrayList(u32).init(arenaForArrayLists.allocator());
		animationTimes = std.ArrayList(u32).init(arenaForArrayLists.allocator());
		blockTextures = std.ArrayList(Image).init(arenaForArrayLists.allocator());
		emissionTextures = std.ArrayList(Image).init(arenaForArrayLists.allocator());
		idToMaterial = std.StringHashMap(u16).init(arenaForArrayLists.allocator());
		arenaForWorld = std.heap.ArenaAllocator.init(std.heap.page_allocator);

		try registerMaterial("cubyz:empty", JsonElement{.JsonNull={}}); // TODO: Proper default.
	}

	pub fn deinit() void {
		animationTimesSSBO.deinit();
		animationFramesSSBO.deinit();
		materialsSSBO.deinit();
		palettesSSBO.deinit();
		blockTextureArray.deinit();
		emissionTextureArray.deinit();
		idToMaterial.deinit();
		arenaForArrayLists.deinit();
		arenaForWorld.deinit();
	}

	pub fn reset() void {
		meshes.size = 0;
		loadedMeshes = 0;
		materialSize = 0;
		textureIDs.clearRetainingCapacity();
		animationFrames.clearRetainingCapacity();
		animationTimes.clearRetainingCapacity();
		blockTextures.clearRetainingCapacity();
		emissionTextures.clearRetainingCapacity();
		idToMaterial.clearRetainingCapacity();
		arenaForWorld.deinit();
		arenaForWorld = std.heap.ArenaAllocator.init(std.heap.page_allocator);

		registerMaterial("cubyz:empty", JsonElement{.JsonNull={}}) catch unreachable; // TODO: Proper default.
	}

	pub fn modelIndices(block: Block) u16 {
		return (&_modelIndices[block.typ]).*;
	}

	pub fn textureIndices(block: Block) *const [6] u32 {
		return &_textureIndices[block.typ];
	}

	fn readTexture(textureInfo: JsonElement, assetFolder: []const u8) !?u31 {
		var result: ?u31 = null;
		if(textureInfo == .JsonString or textureInfo == .JsonStringOwned) {
			const resource = textureInfo.as([]const u8, "");
			var splitter = std.mem.split(u8, resource, ":");
			const mod = splitter.first();
			const id = splitter.rest();
			var buffer: [1024]u8 = undefined;
			var path = try std.fmt.bufPrint(&buffer, "{s}/{s}/blocks/textures/{s}.png", .{assetFolder, mod, id});
			// Test if it's already in the list:
			for(textureIDs.items) |other, j| {
				if(std.mem.eql(u8, other, path)) {
					result = @intCast(u31, j);
					return result;
				}
			}
			var file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
				if(err == error.FileNotFound) {
					path = try std.fmt.bufPrint(&buffer, "assets/{s}/blocks/textures/{s}.png", .{mod, id}); // Default to global assets.
					break :blk std.fs.cwd().openFile(path, .{}) catch |err2| {
						std.log.err("File not found. Searched in \"{s}\" and also in the assetFolder \"{s}\"", .{path, assetFolder});
						return err2;
					};
				} else {
					return err;
				}
			};
			file.close(); // It was only openend to check if it exists.
			// Otherwise read it into the list:
			result = @intCast(u31, blockTextures.items.len);

			try blockTextures.append(Image.readFromFile(arenaForWorld.allocator(), path) catch blk: {
				std.log.warn("Could not read image from: {s}", .{path});
				break :blk undefinedImage;
			});
			path = try std.fmt.bufPrint(&buffer, "{s}_emission.png", .{path});
			const emissionTexture = Image.readFromFile(arenaForWorld.allocator(), path);
			try emissionTextures.append(emissionTexture catch emptyImage);
			try textureIDs.append(try arenaForWorld.allocator().dupe(u8, path));
			try animationFrames.append(1);
			try animationTimes.append(1);
		} else if(textureInfo == .JsonObject) {
			var animationTime = textureInfo.get(u32, "time", 500);
			const textures = textureInfo.getChild("textures");
			if(textures != .JsonArray) return result;
			// Add the new textures into the list. Since this is an animation all textures that weren't found need to be replaced with undefined.
			result = @intCast(u31, blockTextures.items.len);
			for(textures.JsonArray.items) |item, i| {
				if(i == 0) {
					try animationFrames.append(@intCast(u32, textures.JsonArray.items.len));
					try animationTimes.append(animationTime);
				} else {
					try animationFrames.append(1);
					try animationTimes.append(1);
				}
				var splitter = std.mem.split(u8, item.as([]const u8, "cubyz:undefined"), ":");
				const mod = splitter.first();
				const id = splitter.rest();
				var buffer: [1024]u8 = undefined;
				var path = try std.fmt.bufPrint(&buffer, "{s}/{s}/blocks/textures/{s}.png", .{assetFolder, mod, id});
				var file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
					if(err == error.FileNotFound) {
						path = try std.fmt.bufPrint(&buffer, "assets/{s}/blocks/textures/{s}.png", .{mod, id}); // Default to global assets.
						break :blk std.fs.cwd().openFile(path, .{}) catch |err2| {
							std.log.err("File not found. Searched in \"{s}\" and also in the assetFolder \"{s}\"", .{path, assetFolder});
							return err2;
						};
					} else {
						return err;
					}
				};
				file.close(); // It was only openend to check if it exists.

				try blockTextures.append(Image.readFromFile(arenaForWorld.allocator(), path) catch blk: {
					std.log.warn("Could not read image from: {s}", .{path});
					break :blk undefinedImage;
				});
				path = try std.fmt.bufPrint(&buffer, "{s}_emission.png", .{path});
				const emissionTexture = Image.readFromFile(arenaForWorld.allocator(), path);
				try emissionTextures.append(emissionTexture catch emptyImage);
				try textureIDs.append(try arenaForWorld.allocator().dupe(u8, path));
			}
		}
		return result;
	}

	fn readPalette(json: JsonElement, block: u16) !void {
		for(palettes[block].materialReference) |*ref, i| {
			ref.* = idToMaterial.get(json.getAtIndex([]const u8, i, "")) orelse 0;
			std.log.info("{}", .{ref.*});
		}
	}

	fn getTextureIndices(json: JsonElement, assetFolder: []const u8, block: u16) !void {
		var defaultIndex = try readTexture(json.getChild("texture"), assetFolder) orelse 0;
		try readPalette(json.getChild("palette"), block);
		for(_textureIndices[block]) |_, i| {
			_textureIndices[block][i] = defaultIndex;
			const textureInfo = json.getChild(sideNames[i]);
			_textureIndices[block][i] = try readTexture(textureInfo, assetFolder) orelse continue;
		}
	}

	pub fn register(assetFolder: []const u8, _: []const u8, json: JsonElement) !void {
		_modelIndices[meshes.size] = models.getModelIndex(json.get([]const u8, "model", "cube"));

		// The actual model is loaded later, in the rendering thread.
		// But textures can be loaded here:

		try getTextureIndices(json, assetFolder, meshes.size);

		maxTextureCount[meshes.size] = @intCast(u32, textureIDs.items.len);

		meshes.size += 1;
	}

	fn saveInverse(x: f32) f32 {
		if(x == 0) return x;
		return 1.0/x;
	}
	pub fn registerMaterial(id: []const u8, json: JsonElement) !void {
		const numericalID = materialSize;
		try idToMaterial.putNoClobber(try arenaForWorld.allocator().dupe(u8, id), numericalID);

		materials[numericalID].simplex1Wavelength = .{
			saveInverse(json.getChild("simplex1Wavelength").getAtIndex(f32, 0, 0.0)),
			saveInverse(json.getChild("simplex1Wavelength").getAtIndex(f32, 1, 0.0)),
			saveInverse(json.getChild("simplex1Wavelength").getAtIndex(f32, 2, 0.0))
		};
		materials[numericalID].simplex1Weight = json.get(f32, "simplex1Weight", 0.0);

		materials[numericalID].simplex2Wavelength = .{
			saveInverse(json.getChild("simplex2Wavelength").getAtIndex(f32, 0, 0.0)),
			saveInverse(json.getChild("simplex2Wavelength").getAtIndex(f32, 1, 0.0)),
			saveInverse(json.getChild("simplex2Wavelength").getAtIndex(f32, 2, 0.0))
		};
		materials[numericalID].simplex2DomainWarp = .{
			json.getChild("simplex2DomainWarp").getAtIndex(f32, 0, 0.0),
			json.getChild("simplex2DomainWarp").getAtIndex(f32, 1, 0.0),
			json.getChild("simplex2DomainWarp").getAtIndex(f32, 2, 0.0)
		};
		materials[numericalID].simplex2Weight = json.get(f32, "simplex2Weight", 0.0);

		materials[numericalID].simplex3Wavelength = .{
			saveInverse(json.getChild("simplex3Wavelength").getAtIndex(f32, 0, 0.0)),
			saveInverse(json.getChild("simplex3Wavelength").getAtIndex(f32, 1, 0.0)),
			saveInverse(json.getChild("simplex3Wavelength").getAtIndex(f32, 2, 0.0))
		};
		materials[numericalID].simplex3DomainWarp = .{
			json.getChild("simplex3DomainWarp").getAtIndex(f32, 0, 0.0),
			json.getChild("simplex3DomainWarp").getAtIndex(f32, 1, 0.0),
			json.getChild("simplex3DomainWarp").getAtIndex(f32, 2, 0.0)
		};
		materials[numericalID].simplex3Weight = json.get(f32, "simplex3Weight", 0.0);

		materials[numericalID].brightnessOffset = json.get(f32, "brightnessOffset", 0.0);

		materials[numericalID].randomness = json.get(f32, "randomness", 0.0);

		const colors = json.getChild("colors");
		for(materials[numericalID].colors) |*color, i| {
			const colorJson = colors.getChildAtIndex(i);
			if(colorJson == .JsonNull and i > 0) {
				color.* = materials[numericalID].colors[i-1];
			} else {
				color.* = .{
					.diffuse = colorJson.get(u32, "diffuse", 0x000000),
					.emission = colorJson.get(u32, "emission", 0x000000)
				};
			}
		}

		materialSize += 1;
	}

// TODO: (this one requires thinking about the allocated memory!)
//	public static void reloadTextures() {
//		for(int i = 0; i < blockTextures.size(); i++) {
//			try {
//				blockTextures.set(i, ImageIO.read(new File(textureIDs.get(i).replace(":animation", ""))));
//			} catch(IOException e) {
//				Logger.warning("Could not read image from path "+textureIDs.get(i));
//				Logger.warning(e);
//				blockTextures.set(i, blockTextures.get(0));
//			}
//		}
//		generateTextureArray();
//	}


// TODO:
//	public static void loadMeshes() {
//		// Goes through all meshes that were newly added:
//		for(; loadedMeshes < size; loadedMeshes++) {
//			if (meshes[loadedMeshes] == null) {
//				meshes[loadedMeshes] = Meshes.cachedDefaultModels.get(models[loadedMeshes]);
//				if (meshes[loadedMeshes] == null) {
//					if(models[loadedMeshes].isEmpty())
//						continue;
//					Resource rs = new Resource(models[loadedMeshes]);
//					meshes[loadedMeshes] = new Mesh(ModelLoader.loadModel(rs, "assets/" + rs.getMod() + "/models/3d/" + rs.getID()));
//					Meshes.cachedDefaultModels.put(models[loadedMeshes], meshes[loadedMeshes]);
//				}
//			}
//		}
//	}

	pub fn generateTextureArray() !void {
		try blockTextureArray.generate(blockTextures.items, false); // TODO: figure out mipmapping in the voxel model world.
		try emissionTextureArray.generate(emissionTextures.items, false);

		// Also generate additional buffers:
		animationTimesSSBO.bufferData(u32, animationTimes.items);
		animationFramesSSBO.bufferData(u32, animationFrames.items);

		materialsSSBO.bufferData(ProceduralMaterial, materials[0..materialSize]);
		palettesSSBO.bufferData(Palette, palettes[0..meshes.size]);
	}
};
