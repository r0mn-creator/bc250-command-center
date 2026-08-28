#!/usr/bin/env bash
# bc250-graphics-verify.sh - real Vulkan GRAPHICS-pipeline correctness+FPS
# test for the BC-250, written for this project (not vendored).
#
# Why this exists: bc250-compute-verify.sh (vendored from duggasco's project)
# only exercises compute shaders. That's a real GPU workload, but it never
# touches rasterization, texture sampling/filtering, alpha blending, or ROP
# writes - the parts of the chip an actual game hammers hardest. On this
# exact hardware, a GPU undervolt search using the compute-only test found
# 705mV "clean" at 1750MHz, and the system then crashed on the very first
# real game launched at that voltage. This tool closes that gap: it renders
# real textured, blended geometry offscreen (no window/swapchain needed, so
# it also works headlessly under pkexec regardless of session type) and
# reports two numbers a real benchmark would give you - FPS, and whether the
# picture came out right - instead of one compute-shader pass/fail.
#
# Correctness method: every rendered frame is fully DETERMINISTIC (fixed
# geometry, fixed procedural texture, fixed per-frame seed - no time-based
# randomness). Frames cycle through a small set of seeds; the first time a
# given seed is rendered its pixel checksum becomes that seed's "golden"
# value, and every later frame using the same seed must reproduce it
# byte-for-byte. An unstable voltage does not necessarily crash - it can
# just compute the wrong answer sometimes - and this catches that even when
# it's a single flipped bit nowhere near visible to a human eyeballing the
# image, which is a stricter bar than watching a benchmark run.
#
# Must be run where a Vulkan ICD is available. No window/display session
# required - rendering targets an offscreen image, never a swapchain.

set -euo pipefail

WIDTH=1280
HEIGHT=800
GRID=32
LAYERS=4
ITERS=24
FRAMES=32
SEED_CYCLE=8
KEEP_TMP=0

usage() {
	cat <<EOF
Usage: $0 [--width N] [--height N] [--grid N] [--layers N] [--iters N] [--frames N] [--seed-cycle N] [--keep-tmp]

Renders FRAMES offscreen frames of textured, alpha-blended, per-pixel-ALU
geometry (GRID x GRID quads, LAYERS overlapping blended passes per frame,
ITERS shader-ALU iterations per fragment) at WIDTH x HEIGHT, cycling through
SEED_CYCLE distinct deterministic frames and checksumming each one to catch
any pixel that doesn't reproduce exactly on a repeat. Prints per-frame
timing/checksum lines and a final "summary" line with avg/min FPS and a
checksum_mismatches count.

Defaults: ${WIDTH}x${HEIGHT}, grid=$GRID, layers=$LAYERS, iters=$ITERS, frames=$FRAMES, seed-cycle=$SEED_CYCLE
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--width) WIDTH="${2:?missing value for --width}"; shift 2 ;;
		--height) HEIGHT="${2:?missing value for --height}"; shift 2 ;;
		--grid) GRID="${2:?missing value for --grid}"; shift 2 ;;
		--layers) LAYERS="${2:?missing value for --layers}"; shift 2 ;;
		--iters) ITERS="${2:?missing value for --iters}"; shift 2 ;;
		--frames) FRAMES="${2:?missing value for --frames}"; shift 2 ;;
		--seed-cycle) SEED_CYCLE="${2:?missing value for --seed-cycle}"; shift 2 ;;
		--keep-tmp) KEEP_TMP=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

command -v glslangValidator >/dev/null 2>&1 || { echo "ERROR: glslangValidator not found" >&2; exit 1; }
command -v gcc >/dev/null 2>&1 || { echo "ERROR: gcc not found" >&2; exit 1; }

TMPDIR="$(mktemp -d)"
if [ "$KEEP_TMP" -eq 0 ]; then
	trap 'rm -rf "$TMPDIR"' EXIT
else
	echo "Keeping temporary files in $TMPDIR"
fi

cat >"$TMPDIR/bc250_graphics_verify.vert" <<'GLSL'
#version 450

layout(push_constant) uniform Params {
	uint seed;
	uint iters;
	uint grid;
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out vec3 vTint;

vec2 unit_quad(uint vid)
{
	vec2 corners[6] = vec2[](
		vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
		vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
	);
	return corners[vid];
}

float hash11(uint x)
{
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return float(x) / 4294967295.0;
}

void main()
{
	uint cell = uint(gl_InstanceIndex);
	uint cx = cell % pc.grid;
	uint cy = cell / pc.grid;
	vec2 corner = unit_quad(uint(gl_VertexIndex));

	float gx = (float(cx) + corner.x) / float(pc.grid) * 2.0 - 1.0;
	float gy = (float(cy) + corner.y) / float(pc.grid) * 2.0 - 1.0;

	gl_Position = vec4(gx, gy, 0.0, 1.0);
	vUV = corner * 3.0 + vec2(hash11(cell ^ pc.seed), hash11(cell ^ pc.seed ^ 0x9e3779b9u));
	vTint = vec3(hash11(cell ^ pc.seed ^ 0x1u),
	             hash11(cell ^ pc.seed ^ 0x2u),
	             hash11(cell ^ pc.seed ^ 0x3u));
}
GLSL

cat >"$TMPDIR/bc250_graphics_verify.frag" <<'GLSL'
#version 450

layout(push_constant) uniform Params {
	uint seed;
	uint iters;
	uint grid;
} pc;

layout(binding = 0) uniform sampler2D tex;

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vTint;

layout(location = 0) out vec4 outColor;

void main()
{
	vec3 c = texture(tex, vUV).rgb * vTint;
	float a = fract(vUV.x * 7.0 + vUV.y * 13.0 + float(pc.seed) * 0.0001);

	for (uint i = 0u; i < pc.iters; ++i) {
		a = fract(sin(a * 12.9898 + float(i) * 78.233) * 43758.5453);
		c = c * (0.999 + 0.002 * a) + vec3(0.0002 * a, -0.0001 * a, 0.00015 * a);
	}

	outColor = vec4(clamp(c, 0.0, 1.0), 0.35);
}
GLSL

cat >"$TMPDIR/bc250_graphics_verify.c" <<'C'
#define _POSIX_C_SOURCE 200809L

#include <vulkan/vulkan.h>

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(call) do { \
	VkResult _res = (call); \
	if (_res != VK_SUCCESS) { \
		fprintf(stderr, "%s failed: %d at line %d\n", #call, _res, __LINE__); \
		return 1; \
	} \
} while (0)

#define TEX_SIZE 64u
#define MAX_SEED_CYCLE 256u

struct params {
	uint32_t seed;
	uint32_t iters;
	uint32_t grid;
};

static double now_sec(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static uint32_t find_memory_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties props;

	vkGetPhysicalDeviceMemoryProperties(pd, &props);
	for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
		if ((bits & (1u << i)) && (props.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	}
	return UINT32_MAX;
}

static int read_file(const char *path, char **buf, size_t *size)
{
	FILE *f = fopen(path, "rb");
	long len;

	if (!f)
		return 1;
	if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 1; }
	len = ftell(f);
	if (len <= 0) { fclose(f); return 1; }
	rewind(f);
	*buf = malloc((size_t)len);
	if (!*buf) { fclose(f); return 1; }
	if (fread(*buf, 1, (size_t)len, f) != (size_t)len) { fclose(f); free(*buf); return 1; }
	fclose(f);
	*size = (size_t)len;
	return 0;
}

static VkShaderModule load_shader(VkDevice dev, const char *path)
{
	char *spv = NULL;
	size_t spv_size = 0;
	VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
	VkShaderModule mod = VK_NULL_HANDLE;

	if (read_file(path, &spv, &spv_size))
		return VK_NULL_HANDLE;
	smci.codeSize = spv_size;
	smci.pCode = (const uint32_t *)spv;
	if (vkCreateShaderModule(dev, &smci, NULL, &mod) != VK_SUCCESS)
		mod = VK_NULL_HANDLE;
	free(spv);
	return mod;
}

/* FNV-1a 64-bit - simple, fast, no external dependency. */
static uint64_t fnv1a64(const void *data, size_t len)
{
	const uint8_t *p = (const uint8_t *)data;
	uint64_t h = 0xcbf29ce484222325ULL;

	for (size_t i = 0; i < len; ++i) {
		h ^= p[i];
		h *= 0x100000001b3ULL;
	}
	return h;
}

static VkCommandBuffer begin_one_shot(VkDevice dev, VkCommandPool pool)
{
	VkCommandBufferAllocateInfo cbai = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
		.commandBufferCount = 1,
	};
	VkCommandBufferBeginInfo cbbi = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
	};
	VkCommandBuffer cmd;

	vkAllocateCommandBuffers(dev, &cbai, &cmd);
	vkBeginCommandBuffer(cmd, &cbbi);
	return cmd;
}

static void end_one_shot(VkDevice dev, VkCommandPool pool, VkQueue queue, VkCommandBuffer cmd)
{
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };

	vkEndCommandBuffer(cmd);
	vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
	vkQueueWaitIdle(queue);
	vkFreeCommandBuffers(dev, pool, 1, &cmd);
}

int main(int argc, char **argv)
{
	if (argc != 9) {
		fprintf(stderr, "usage: %s vert.spv frag.spv width height grid layers iters frames:seed_cycle\n", argv[0]);
		return 2;
	}

	const char *vert_path = argv[1];
	const char *frag_path = argv[2];
	uint32_t width = (uint32_t)strtoul(argv[3], NULL, 0);
	uint32_t height = (uint32_t)strtoul(argv[4], NULL, 0);
	uint32_t grid = (uint32_t)strtoul(argv[5], NULL, 0);
	uint32_t layers = (uint32_t)strtoul(argv[6], NULL, 0);
	uint32_t iters = (uint32_t)strtoul(argv[7], NULL, 0);
	uint32_t frames, seed_cycle;
	{
		char *arg8 = argv[8];
		char *colon = strchr(arg8, ':');
		if (!colon) { fprintf(stderr, "last arg must be frames:seed_cycle\n"); return 2; }
		*colon = 0;
		frames = (uint32_t)strtoul(arg8, NULL, 0);
		seed_cycle = (uint32_t)strtoul(colon + 1, NULL, 0);
	}

	if (!width || !height || !grid || !layers || !frames || !seed_cycle || seed_cycle > MAX_SEED_CYCLE) {
		fprintf(stderr, "invalid width/height/grid/layers/frames/seed_cycle\n");
		return 2;
	}

	VkApplicationInfo app = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "bc250-graphics-verify",
		.apiVersion = VK_API_VERSION_1_1,
	};
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CHECK(vkCreateInstance(&ici, NULL, &instance));

	VkPhysicalDevice pds[16];
	uint32_t pd_count = 16;
	VkPhysicalDevice pd = VK_NULL_HANDLE;
	VkPhysicalDeviceProperties pd_props;

	CHECK(vkEnumeratePhysicalDevices(instance, &pd_count, pds));
	for (uint32_t i = 0; i < pd_count; ++i) {
		vkGetPhysicalDeviceProperties(pds[i], &pd_props);
		if (pd_props.vendorID == 0x1002 && strstr(pd_props.deviceName, "BC-250")) { pd = pds[i]; break; }
	}
	if (pd == VK_NULL_HANDLE) {
		for (uint32_t i = 0; i < pd_count; ++i) {
			vkGetPhysicalDeviceProperties(pds[i], &pd_props);
			if (pd_props.vendorID == 0x1002) { pd = pds[i]; break; }
		}
	}
	if (pd == VK_NULL_HANDLE) { fprintf(stderr, "AMD Vulkan device not found\n"); return 1; }
	vkGetPhysicalDeviceProperties(pd, &pd_props);

	uint32_t queue_family = UINT32_MAX;
	VkQueueFamilyProperties qprops[32];
	uint32_t qcount = 32;

	vkGetPhysicalDeviceQueueFamilyProperties(pd, &qcount, qprops);
	for (uint32_t i = 0; i < qcount; ++i) {
		if (qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { queue_family = i; break; }
	}
	if (queue_family == UINT32_MAX) { fprintf(stderr, "graphics queue not found\n"); return 1; }

	float priority = 1.0f;
	VkDeviceQueueCreateInfo qci = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = queue_family,
		.queueCount = 1,
		.pQueuePriorities = &priority,
	};
	VkDeviceCreateInfo dci = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci,
	};
	VkDevice dev;
	VkQueue queue;

	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, queue_family, 0, &queue);

	VkCommandPoolCreateInfo cmdp_ci = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
		.queueFamilyIndex = queue_family,
	};
	VkCommandPool cmd_pool;
	CHECK(vkCreateCommandPool(dev, &cmdp_ci, NULL, &cmd_pool));

	/* --- Offscreen color target --- */
	VkFormat color_fmt = VK_FORMAT_R8G8B8A8_UNORM;
	VkImageCreateInfo ici_color = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = VK_IMAGE_TYPE_2D,
		.format = color_fmt,
		.extent = { width, height, 1 },
		.mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
		.sharingMode = VK_SHARING_MODE_EXCLUSIVE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	};
	VkImage color_img;
	CHECK(vkCreateImage(dev, &ici_color, NULL, &color_img));

	VkMemoryRequirements color_req;
	vkGetImageMemoryRequirements(dev, color_img, &color_req);
	VkMemoryAllocateInfo color_mai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = color_req.size,
		.memoryTypeIndex = find_memory_type(pd, color_req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
	};
	VkDeviceMemory color_mem;
	CHECK(vkAllocateMemory(dev, &color_mai, NULL, &color_mem));
	CHECK(vkBindImageMemory(dev, color_img, color_mem, 0));

	VkImageViewCreateInfo color_ivci = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.image = color_img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = color_fmt,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
	};
	VkImageView color_view;
	CHECK(vkCreateImageView(dev, &color_ivci, NULL, &color_view));

	/* --- Render pass + framebuffer --- */
	VkAttachmentDescription att = {
		.format = color_fmt, .samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	};
	VkAttachmentReference att_ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription subpass = {
		.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1, .pColorAttachments = &att_ref,
	};
	VkSubpassDependency deps[2] = {
		{
			.srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0,
			.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			.srcAccessMask = 0, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		},
		{
			.srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL,
			.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			.dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
			.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
		},
	};
	VkRenderPassCreateInfo rpci = {
		.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &att,
		.subpassCount = 1, .pSubpasses = &subpass,
		.dependencyCount = 2, .pDependencies = deps,
	};
	VkRenderPass render_pass;
	CHECK(vkCreateRenderPass(dev, &rpci, NULL, &render_pass));

	VkFramebufferCreateInfo fbci = {
		.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
		.renderPass = render_pass, .attachmentCount = 1, .pAttachments = &color_view,
		.width = width, .height = height, .layers = 1,
	};
	VkFramebuffer framebuffer;
	CHECK(vkCreateFramebuffer(dev, &fbci, NULL, &framebuffer));

	/* --- Procedural texture --- */
	VkDeviceSize tex_bytes = (VkDeviceSize)TEX_SIZE * TEX_SIZE * 4;
	VkBufferCreateInfo stage_bci = {
		.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = tex_bytes,
		.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
	};
	VkBuffer stage_buf;
	CHECK(vkCreateBuffer(dev, &stage_bci, NULL, &stage_buf));
	VkMemoryRequirements stage_req;
	vkGetBufferMemoryRequirements(dev, stage_buf, &stage_req);
	VkMemoryAllocateInfo stage_mai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = stage_req.size,
		.memoryTypeIndex = find_memory_type(pd, stage_req.memoryTypeBits,
			VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
	};
	VkDeviceMemory stage_mem;
	CHECK(vkAllocateMemory(dev, &stage_mai, NULL, &stage_mem));
	CHECK(vkBindBufferMemory(dev, stage_buf, stage_mem, 0));

	void *stage_map;
	CHECK(vkMapMemory(dev, stage_mem, 0, tex_bytes, 0, &stage_map));
	{
		uint8_t *px = (uint8_t *)stage_map;
		for (uint32_t y = 0; y < TEX_SIZE; ++y) {
			for (uint32_t x = 0; x < TEX_SIZE; ++x) {
				uint32_t checker = ((x / 8) + (y / 8)) & 1u;
				uint32_t h = (x * 374761393u + y * 668265263u);
				h = (h ^ (h >> 13)) * 1274126177u;
				uint8_t noise = (uint8_t)(h & 0x3fu);
				uint8_t base = checker ? 200 : 80;
				uint8_t *p = px + (y * TEX_SIZE + x) * 4;
				p[0] = (uint8_t)(base + noise / 2);
				p[1] = (uint8_t)(base - noise / 3);
				p[2] = (uint8_t)((base + 255) / 2);
				p[3] = 255;
			}
		}
	}
	vkUnmapMemory(dev, stage_mem);

	VkImageCreateInfo tex_ici = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = color_fmt,
		.extent = { TEX_SIZE, TEX_SIZE, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
		.sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	};
	VkImage tex_img;
	CHECK(vkCreateImage(dev, &tex_ici, NULL, &tex_img));
	VkMemoryRequirements tex_req;
	vkGetImageMemoryRequirements(dev, tex_img, &tex_req);
	VkMemoryAllocateInfo tex_mai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = tex_req.size,
		.memoryTypeIndex = find_memory_type(pd, tex_req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
	};
	VkDeviceMemory tex_mem;
	CHECK(vkAllocateMemory(dev, &tex_mai, NULL, &tex_mem));
	CHECK(vkBindImageMemory(dev, tex_img, tex_mem, 0));

	{
		VkCommandBuffer cmd = begin_one_shot(dev, cmd_pool);
		VkImageMemoryBarrier b1 = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
			.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
			.image = tex_img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
			.srcAccessMask = 0, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		};
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
			0, 0, NULL, 0, NULL, 1, &b1);

		VkBufferImageCopy region = {
			.bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
			.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
			.imageOffset = { 0, 0, 0 }, .imageExtent = { TEX_SIZE, TEX_SIZE, 1 },
		};
		vkCmdCopyBufferToImage(cmd, stage_buf, tex_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

		VkImageMemoryBarrier b2 = b1;
		b2.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		b2.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
		b2.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		b2.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
			0, 0, NULL, 0, NULL, 1, &b2);

		end_one_shot(dev, cmd_pool, queue, cmd);
	}
	vkDestroyBuffer(dev, stage_buf, NULL);
	vkFreeMemory(dev, stage_mem, NULL);

	VkImageViewCreateInfo tex_ivci = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.image = tex_img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = color_fmt,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
	};
	VkImageView tex_view;
	CHECK(vkCreateImageView(dev, &tex_ivci, NULL, &tex_view));

	VkSamplerCreateInfo sci = {
		.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
		.magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR,
		.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
		.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT, .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT,
		.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT,
		.maxAnisotropy = 1.0f, .maxLod = 0.0f,
	};
	VkSampler sampler;
	CHECK(vkCreateSampler(dev, &sci, NULL, &sampler));

	/* --- Descriptors --- */
	VkDescriptorSetLayoutBinding dslb = {
		.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
	};
	VkDescriptorSetLayoutCreateInfo dslci = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &dslb,
	};
	VkDescriptorSetLayout dsl;
	CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));

	VkDescriptorPoolSize dps = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 };
	VkDescriptorPoolCreateInfo dpci = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &dps,
	};
	VkDescriptorPool dpool;
	CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));

	VkDescriptorSetAllocateInfo dsai = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl,
	};
	VkDescriptorSet ds;
	CHECK(vkAllocateDescriptorSets(dev, &dsai, &ds));

	VkDescriptorImageInfo dii = { sampler, tex_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
	VkWriteDescriptorSet wds = {
		.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0,
		.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		.pImageInfo = &dii,
	};
	vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);

	/* --- Pipeline --- */
	VkShaderModule vert = load_shader(dev, vert_path);
	VkShaderModule frag = load_shader(dev, frag_path);
	if (!vert || !frag) { fprintf(stderr, "failed to load shader modules\n"); return 1; }

	VkPushConstantRange pcr = {
		.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
		.offset = 0, .size = sizeof(struct params),
	};
	VkPipelineLayoutCreateInfo plci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &dsl,
		.pushConstantRangeCount = 1, .pPushConstantRanges = &pcr,
	};
	VkPipelineLayout pipeline_layout;
	CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &pipeline_layout));

	VkPipelineShaderStageCreateInfo stages[2] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, vert, "main", NULL },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, frag, "main", NULL },
	};
	VkPipelineVertexInputStateCreateInfo visci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo iasci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	};
	VkViewport viewport = { 0, 0, (float)width, (float)height, 0.0f, 1.0f };
	VkRect2D scissor = { { 0, 0 }, { width, height } };
	VkPipelineViewportStateCreateInfo vpsci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor,
	};
	VkPipelineRasterizationStateCreateInfo rsci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
		.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f,
	};
	VkPipelineMultisampleStateCreateInfo msci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
	};
	VkPipelineColorBlendAttachmentState cbas = {
		.blendEnable = VK_TRUE,
		.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA, .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
		.colorBlendOp = VK_BLEND_OP_ADD,
		.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
		.alphaBlendOp = VK_BLEND_OP_ADD,
		.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
	};
	VkPipelineColorBlendStateCreateInfo cbsci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cbas,
	};
	VkGraphicsPipelineCreateInfo gpci = {
		.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.stageCount = 2, .pStages = stages,
		.pVertexInputState = &visci, .pInputAssemblyState = &iasci, .pViewportState = &vpsci,
		.pRasterizationState = &rsci, .pMultisampleState = &msci, .pColorBlendState = &cbsci,
		.layout = pipeline_layout, .renderPass = render_pass, .subpass = 0,
	};
	VkPipeline pipeline;
	CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipeline));

	/* --- Readback buffer --- */
	VkDeviceSize fb_bytes = (VkDeviceSize)width * height * 4;
	VkBufferCreateInfo rb_bci = {
		.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = fb_bytes,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
	};
	VkBuffer rb_buf;
	CHECK(vkCreateBuffer(dev, &rb_bci, NULL, &rb_buf));
	VkMemoryRequirements rb_req;
	vkGetBufferMemoryRequirements(dev, rb_buf, &rb_req);
	VkMemoryAllocateInfo rb_mai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = rb_req.size,
		.memoryTypeIndex = find_memory_type(pd, rb_req.memoryTypeBits,
			VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
	};
	VkDeviceMemory rb_mem;
	CHECK(vkAllocateMemory(dev, &rb_mai, NULL, &rb_mem));
	CHECK(vkBindBufferMemory(dev, rb_buf, rb_mem, 0));
	void *rb_map;
	CHECK(vkMapMemory(dev, rb_mem, 0, fb_bytes, 0, &rb_map));

	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CHECK(vkCreateFence(dev, &fci, NULL, &fence));

	printf("device=%s queue_family=%u %ux%u grid=%u layers=%u iters=%u frames=%u seed_cycle=%u\n",
	       pd_props.deviceName, queue_family, width, height, grid, layers, iters, frames, seed_cycle);

	uint64_t golden[MAX_SEED_CYCLE] = {0};
	int has_golden[MAX_SEED_CYCLE] = {0};
	uint64_t mismatches = 0;
	double total_time = 0.0;
	double min_frame_time = 1e300;
	VkClearValue clear = { .color = { { 0.0f, 0.0f, 0.0f, 1.0f } } };

	for (uint32_t f = 0; f < frames; ++f) {
		uint32_t seed_idx = f % seed_cycle;

		VkCommandBufferAllocateInfo cbai = {
			.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
			.commandPool = cmd_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1,
		};
		VkCommandBuffer cmd;
		CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

		VkCommandBufferBeginInfo cbbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CHECK(vkBeginCommandBuffer(cmd, &cbbi));

		VkRenderPassBeginInfo rpbi = {
			.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
			.renderPass = render_pass, .framebuffer = framebuffer,
			.renderArea = { { 0, 0 }, { width, height } },
			.clearValueCount = 1, .pClearValues = &clear,
		};
		vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout, 0, 1, &ds, 0, NULL);

		for (uint32_t layer = 0; layer < layers; ++layer) {
			struct params pc = { .seed = seed_idx * 1000u + layer, .iters = iters, .grid = grid };
			vkCmdPushConstants(cmd, pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
				0, sizeof(pc), &pc);
			vkCmdDraw(cmd, 6, grid * grid, 0, 0);
		}

		vkCmdEndRenderPass(cmd);

		VkBufferImageCopy region = {
			.bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
			.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
			.imageOffset = { 0, 0, 0 }, .imageExtent = { width, height, 1 },
		};
		vkCmdCopyImageToBuffer(cmd, color_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb_buf, 1, &region);

		CHECK(vkEndCommandBuffer(cmd));

		VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		double t0 = now_sec();
		CHECK(vkQueueSubmit(queue, 1, &si, fence));
		CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
		double t1 = now_sec();
		CHECK(vkResetFences(dev, 1, &fence));

		uint64_t checksum = fnv1a64(rb_map, (size_t)fb_bytes);
		double dt = t1 - t0;
		total_time += dt;
		if (dt < min_frame_time)
			min_frame_time = dt;

		int mismatch = 0;
		if (!has_golden[seed_idx]) {
			golden[seed_idx] = checksum;
			has_golden[seed_idx] = 1;
		} else if (checksum != golden[seed_idx]) {
			mismatch = 1;
			mismatches++;
		}

		printf("frame=%u seed=%u ms=%.3f checksum=0x%016" PRIx64 "%s\n",
		       f, seed_idx, dt * 1000.0, checksum,
		       mismatch ? " MISMATCH" : (has_golden[seed_idx] && golden[seed_idx] == checksum && f >= seed_cycle ? " (repeat OK)" : ""));

		vkFreeCommandBuffers(dev, cmd_pool, 1, &cmd);
	}

	double avg_fps = total_time > 0.0 ? (double)frames / total_time : 0.0;
	double min_fps = min_frame_time > 0.0 ? 1.0 / min_frame_time : 0.0;

	printf("summary frames=%u duration_sec=%.3f avg_fps=%.2f min_fps=%.2f checksum_mismatches=%" PRIu64 "\n",
	       frames, total_time, avg_fps, min_fps, mismatches);

	vkDestroyFence(dev, fence, NULL);
	vkUnmapMemory(dev, rb_mem);
	vkFreeMemory(dev, rb_mem, NULL);
	vkDestroyBuffer(dev, rb_buf, NULL);
	vkDestroyPipeline(dev, pipeline, NULL);
	vkDestroyPipelineLayout(dev, pipeline_layout, NULL);
	vkDestroyShaderModule(dev, vert, NULL);
	vkDestroyShaderModule(dev, frag, NULL);
	vkDestroyDescriptorPool(dev, dpool, NULL);
	vkDestroyDescriptorSetLayout(dev, dsl, NULL);
	vkDestroySampler(dev, sampler, NULL);
	vkDestroyImageView(dev, tex_view, NULL);
	vkDestroyImage(dev, tex_img, NULL);
	vkFreeMemory(dev, tex_mem, NULL);
	vkDestroyFramebuffer(dev, framebuffer, NULL);
	vkDestroyRenderPass(dev, render_pass, NULL);
	vkDestroyImageView(dev, color_view, NULL);
	vkDestroyImage(dev, color_img, NULL);
	vkFreeMemory(dev, color_mem, NULL);
	vkDestroyCommandPool(dev, cmd_pool, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);

	return mismatches ? 2 : 0;
}
C

echo "Compiling graphics verifier..."
glslangValidator -V "$TMPDIR/bc250_graphics_verify.vert" -o "$TMPDIR/bc250_graphics_verify.vert.spv" >/dev/null
glslangValidator -V "$TMPDIR/bc250_graphics_verify.frag" -o "$TMPDIR/bc250_graphics_verify.frag.spv" >/dev/null
gcc -std=c11 -O2 -Wall -Wextra -o "$TMPDIR/bc250_graphics_verify" \
	"$TMPDIR/bc250_graphics_verify.c" -lvulkan -lm

echo "Running BC-250 graphics verifier..."
"$TMPDIR/bc250_graphics_verify" \
	"$TMPDIR/bc250_graphics_verify.vert.spv" "$TMPDIR/bc250_graphics_verify.frag.spv" \
	"$WIDTH" "$HEIGHT" "$GRID" "$LAYERS" "$ITERS" "$FRAMES:$SEED_CYCLE"
