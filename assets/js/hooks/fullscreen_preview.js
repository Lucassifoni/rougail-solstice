const FULLSCREEN_DURATION_MS = 2000;

export function initFullscreenPreview(hook) {
  hook._fullscreenTimeout = null;
  hook._isFullscreen = false;
}

export function triggerFullscreen(hook) {
  if (hook._fullscreenTimeout) {
    clearTimeout(hook._fullscreenTimeout);
    hook._fullscreenTimeout = null;
  }

  if (!hook._isFullscreen) {
    hook.el.classList.add("canvas-fullscreen-overlay");
    hook._isFullscreen = true;
    if (hook.draw) hook.draw();
  }

  hook._fullscreenTimeout = setTimeout(() => {
    exitFullscreen(hook);
  }, FULLSCREEN_DURATION_MS);
}

export function exitFullscreen(hook) {
  if (!hook._isFullscreen) return;

  hook.el.classList.add("fade-out");

  setTimeout(() => {
    hook.el.classList.remove("canvas-fullscreen-overlay", "fade-out");
    hook._isFullscreen = false;
    if (hook.draw) hook.draw();
  }, 200);

  if (hook._fullscreenTimeout) {
    clearTimeout(hook._fullscreenTimeout);
    hook._fullscreenTimeout = null;
  }
}
