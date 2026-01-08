const PreviewCanvas = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.image = new Image();
    this.circle = { cx: 0, cy: 0, r: 100 };
    this.dragging = null;
    this.imageLoaded = false;

    this.image.onload = () => {
      this.imageLoaded = true;
      this.draw();
    };

    this.canvas.addEventListener("mousedown", (e) => this.onMouseDown(e));
    this.canvas.addEventListener("mousemove", (e) => this.onMouseMove(e));
    this.canvas.addEventListener("mouseup", () => this.onMouseUp());
    this.canvas.addEventListener("mouseleave", () => this.onMouseUp());

    this.handleEvent("update_preview_image", ({ src }) => {
      this.image.src = src + "?v=" + Date.now();
    });

    this.handleEvent("set_circle", (circle) => {
      this.circle = circle;
      this.draw();
    });
  },

  draw() {
    const { canvas, ctx, image, circle } = this;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (this.imageLoaded && image.naturalWidth > 0) {
      const scale = Math.min(
        canvas.width / image.naturalWidth,
        canvas.height / image.naturalHeight
      );
      const imgW = image.naturalWidth * scale;
      const imgH = image.naturalHeight * scale;
      const x = (canvas.width - imgW) / 2;
      const y = (canvas.height - imgH) / 2;
      ctx.drawImage(image, x, y, imgW, imgH);

      this.imageOffset = { x, y, scale };
    }

    ctx.strokeStyle = "#00ff00";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(circle.cx, circle.cy, circle.r, 0, Math.PI * 2);
    ctx.stroke();

    ctx.fillStyle = "#00ff00";
    ctx.beginPath();
    ctx.arc(circle.cx, circle.cy, 6, 0, Math.PI * 2);
    ctx.fill();

    ctx.beginPath();
    ctx.arc(circle.cx + circle.r, circle.cy, 6, 0, Math.PI * 2);
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

  onMouseDown(e) {
    const pos = this.getCanvasCoords(e);
    const { cx, cy, r } = this.circle;

    const distToCenter = Math.sqrt((pos.x - cx) ** 2 + (pos.y - cy) ** 2);
    const distToEdge = Math.abs(distToCenter - r);

    if (distToCenter < 15) {
      this.dragging = "center";
    } else if (distToEdge < 15) {
      this.dragging = "radius";
    }
  },

  onMouseMove(e) {
    if (!this.dragging) return;

    const pos = this.getCanvasCoords(e);

    if (this.dragging === "center") {
      this.circle.cx = Math.round(pos.x);
      this.circle.cy = Math.round(pos.y);
    } else if (this.dragging === "radius") {
      const dist = Math.sqrt(
        (pos.x - this.circle.cx) ** 2 + (pos.y - this.circle.cy) ** 2
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
  }
};

export default PreviewCanvas;
