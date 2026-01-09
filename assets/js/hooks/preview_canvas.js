import { initFullscreenPreview, triggerFullscreen } from "./fullscreen_preview";

const PreviewCanvas = {
  mounted() {
    initFullscreenPreview(this);
    console.log("[PreviewCanvas] mounted");
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.image = new Image();
    this.edgesImage = new Image();
    this.circle = { cx: 0, cy: 0, r: 100 };
    this.dragging = null;
    this.imageLoaded = false;
    this.edgesLoaded = false;
    this.showEdgesOverlay = true;

    this.image.onload = () => {
      console.log("[PreviewCanvas] image loaded", this.image.naturalWidth, "x", this.image.naturalHeight);
      this.imageLoaded = true;
      this.draw();
    };

    this.image.onerror = (e) => {
      console.error("[PreviewCanvas] image load error", e);
    };

    this.edgesImage.onload = () => {
      console.log("[PreviewCanvas] edges loaded", this.edgesImage.naturalWidth, "x", this.edgesImage.naturalHeight);
      this.edgesLoaded = true;
      this.draw();
    };

    this.edgesImage.onerror = (e) => {
      console.error("[PreviewCanvas] edges load error", e);
      this.edgesLoaded = false;
    };

    this.canvas.addEventListener("mousedown", (e) => this.onMouseDown(e));
    this.canvas.addEventListener("mousemove", (e) => this.onMouseMove(e));
    this.canvas.addEventListener("mouseup", () => this.onMouseUp());
    this.canvas.addEventListener("mouseleave", () => this.onMouseUp());

    this.handleEvent("update_preview_image", ({ src }) => {
      console.log("[PreviewCanvas] received update_preview_image", src);
      this.image.src = src + "?v=" + Date.now();
    });

    this.handleEvent("set_circle", (circle) => {
      this.circle = circle;
      this.draw();
    });

    this.handleEvent("update_edges_overlay", (payload) => {
      try {
        console.log("[PreviewCanvas] received update_edges_overlay", payload);
        if (payload && payload.src) {
          this.edgesImage.src = payload.src;
        }
      } catch (e) {
        console.error("[PreviewCanvas] error in update_edges_overlay", e);
      }
    });

    this._onOutlineAdjusted = () => triggerFullscreen(this);
    window.addEventListener("outline-adjusted", this._onOutlineAdjusted);
  },

  draw() {
    const { canvas, ctx, image, circle, edgesImage } = this;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    let offsetX = 0;
    let offsetY = 0;

    if (this.imageLoaded && image.naturalWidth > 0) {
      const scale = Math.min(
        canvas.width / image.naturalWidth,
        canvas.height / image.naturalHeight
      );
      const imgW = image.naturalWidth * scale;
      const imgH = image.naturalHeight * scale;
      offsetX = (canvas.width - imgW) / 2;
      offsetY = (canvas.height - imgH) / 2;
      ctx.drawImage(image, offsetX, offsetY, imgW, imgH);

      this.imageOffset = { x: offsetX, y: offsetY, scale };
    }

    if (this.showEdgesOverlay && this.edgesLoaded && edgesImage && edgesImage.naturalWidth > 0) {
      const edgeScale = Math.min(
        canvas.width / edgesImage.naturalWidth,
        canvas.height / edgesImage.naturalHeight
      );
      const edgeW = edgesImage.naturalWidth * edgeScale;
      const edgeH = edgesImage.naturalHeight * edgeScale;
      const edgeX = (canvas.width - edgeW) / 2;
      const edgeY = (canvas.height - edgeH) / 2;

      ctx.globalCompositeOperation = "lighten";
      ctx.drawImage(edgesImage, edgeX, edgeY, edgeW, edgeH);
      ctx.globalCompositeOperation = "source-over";
    }

    const drawCx = circle.cx + offsetX;
    const drawCy = circle.cy + offsetY;

    const isFullscreen = this.el.classList.contains("canvas-fullscreen-overlay");
    const lineWidth = isFullscreen ? 1 : 2;
    const handleSize = isFullscreen ? 3 : 6;

    ctx.strokeStyle = "#00ff00";
    ctx.lineWidth = lineWidth;
    ctx.beginPath();
    ctx.arc(drawCx, drawCy, circle.r, 0, Math.PI * 2);
    ctx.stroke();

    ctx.fillStyle = "#00ff00";
    ctx.beginPath();
    ctx.arc(drawCx, drawCy, handleSize, 0, Math.PI * 2);
    ctx.fill();

    ctx.beginPath();
    ctx.arc(drawCx + circle.r, drawCy, handleSize, 0, Math.PI * 2);
    ctx.fill();
  },

  getCanvasCoords(e) {
    const rect = this.canvas.getBoundingClientRect();
    const scaleX = this.canvas.width / rect.width;
    const scaleY = this.canvas.height / rect.height;
    return {
      x: (e.clientX - rect.left) * scaleX,
      y: (e.clientY - rect.top) * scaleY
    };
  },

  toImageSpace(canvasPos) {
    const offset = this.imageOffset || { x: 0, y: 0 };
    return {
      x: canvasPos.x - offset.x,
      y: canvasPos.y - offset.y
    };
  },

  onMouseDown(e) {
    const canvasPos = this.getCanvasCoords(e);
    const imgPos = this.toImageSpace(canvasPos);
    const { cx, cy, r } = this.circle;

    const distToCenter = Math.sqrt((imgPos.x - cx) ** 2 + (imgPos.y - cy) ** 2);
    const distToEdge = Math.abs(distToCenter - r);

    if (distToCenter < 15) {
      this.dragging = "center";
      triggerFullscreen(this);
    } else if (distToEdge < 15) {
      this.dragging = "radius";
      triggerFullscreen(this);
    }
  },

  onMouseMove(e) {
    if (!this.dragging) return;

    const canvasPos = this.getCanvasCoords(e);
    const imgPos = this.toImageSpace(canvasPos);

    if (this.dragging === "center") {
      this.circle.cx = Math.round(imgPos.x);
      this.circle.cy = Math.round(imgPos.y);
    } else if (this.dragging === "radius") {
      const dist = Math.sqrt(
        (imgPos.x - this.circle.cx) ** 2 + (imgPos.y - this.circle.cy) ** 2
      );
      this.circle.r = Math.max(10, Math.round(dist));
    }

    this.draw();
    this.pushCircleUpdate();
  },

  onMouseUp() {
    if (this.dragging) {
      this.dragging = null;
      this.pushCircleUpdate();
    }
  },

  pushCircleUpdate() {
    this.pushEvent("update_outline_circle", {
      cx: this.circle.cx,
      cy: this.circle.cy,
      r: this.circle.r
    });
  },

  destroyed() {
    this.canvas.removeEventListener("mousedown", this.onMouseDown);
    this.canvas.removeEventListener("mousemove", this.onMouseMove);
    this.canvas.removeEventListener("mouseup", this.onMouseUp);
    this.canvas.removeEventListener("mouseleave", this.onMouseUp);
    window.removeEventListener("outline-adjusted", this._onOutlineAdjusted);
  }
};

export default PreviewCanvas;
