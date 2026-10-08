--!strict
-- World-grid constants shared by the generator, the server and the tests.
-- Everything here is in studs unless the name says voxels.

local VOXEL_SIZE = 4 -- Roblox terrain resolution; WriteVoxelChannels only accepts 4.
local CHUNK_VOXELS = 16 -- Horizontal chunk edge, in voxels.

return table.freeze({
	VOXEL_SIZE = VOXEL_SIZE,
	CHUNK_VOXELS = CHUNK_VOXELS,
	CHUNK_STUDS = VOXEL_SIZE * CHUNK_VOXELS,

	-- Vertical extent every chunk is allowed to occupy. Both must be multiples of VOXEL_SIZE.
	WORLD_BOTTOM = -128,
	WORLD_TOP = 512,

	-- Solid layers below the surface before switching to stone.
	SUBSURFACE_DEPTH = 12,
})
