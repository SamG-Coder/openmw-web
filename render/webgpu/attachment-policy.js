// SPDX-License-Identifier: GPL-3.0-or-later
// Native clear policy. Eligibility does not imply that preserved planes exist;
// the game host must still check attachment authority/initialization.
const COLOR = 0x4000, DEPTH = 0x0100, STENCIL = 0x0400;
const ALL = COLOR | DEPTH | STENCIL;

export function canUseNativeCamera(pass, compact = false) {
  const samples = pass.sampleCount ?? 1;
  if (samples !== 1 && samples !== 4) return false;
  if (pass.stencilTargetId && pass.depthTargetId && pass.stencilTargetId !== pass.depthTargetId) return false;
  const mask = pass.clearMask ?? (COLOR | DEPTH);
  if (!Number.isInteger(mask) || mask < 0 || (mask & ~ALL) !== 0 || mask > ALL) return false;
  const viewport = pass.viewport ?? [0, 0, pass.width, pass.height];
  if (mask !== 0) {
    if (viewport[0] !== 0 || viewport[1] !== 0 || viewport[2] !== pass.width || viewport[3] !== pass.height) return false;
    // loadOp can clear an entire plane, not selected channels or a subrectangle.
    if (!compact && (mask & COLOR) && (pass.clearColorMask ?? 15) !== 15) return false;
  }
  return true;
}

function clearColor(value, channels) {
  return Array.from({length: 4}, (_, index) => index < channels ? value[index] : index === 3 ? 1 : 0);
}

export function nativeCameraAttachments(attachments, config, params, pass) {
  const mask = pass.clearMask ?? (COLOR | DEPTH);
  if (!canUseNativeCamera({...pass, width: config.width, height: config.height}, config.compact))
    throw new Error('Native camera clear requires full planes and a full clear viewport');
  const color = pass.clearColor ?? [0, 0, 0, 1];
  // Clone descriptors: the later render/query passes must load, not repeat a clear.
  const colorAttachments = attachments.colorAttachments.map((attachment, index) => ({...attachment,
    loadOp: mask & COLOR ? 'clear' : 'load',
    clearValue: clearColor(color, index === 0 ? params.color_channels : params.normal_channels),
  }));
  const depthStencilAttachment = {...attachments.depthStencilAttachment,
    depthLoadOp: mask & DEPTH ? 'clear' : 'load', depthClearValue: pass.clearDepth ?? 1,
    ...(config.stencil ? {stencilLoadOp: mask & STENCIL ? 'clear' : 'load', stencilClearValue: (pass.clearStencil ?? 0) & 255} : {}),
  };
  return {...attachments, colorAttachments, depthStencilAttachment};
}

export function attachmentBridgeKey(config) {
  // Extents and channel counts are uniforms, not shader/pipeline specialization.
  // Keep physical texture allocation keys separate from this compile-cache key.
  return JSON.stringify([config.samples, config.compact, config.normal, config.stencil,
    config.colorFormat, config.normalFormat, config.depthFormat]);
}
