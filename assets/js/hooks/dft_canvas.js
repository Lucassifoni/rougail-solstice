const DftCanvas = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.image = new Image();
    this.radius = 10;
    this.dragging = false;
    this.imageLoaded = false;

    this.image.onload = () => {
      this.imageLoaded = true;
      this.draw();
    };

    this.canvas.addEventListener("mousedown", (e) => this.onMouseDown(e));
    this.canvas.addEventListener("mousemove", (e) => this.onMouseMove(e));
    this.canvas.addEventListener("mouseup", () => this.onMouseUp());
    this.canvas.addEventListener("mouseleave", () => this.onMouseUp());

    this.handleEvent("update_dft_image", ({ src }) => {
      this.image.src = src + "?v=" + Date.now();
    });

    this.handleEvent("set_center_filter", ({ radius }) => {
      this.radius = radius;
      this.draw();
    });
  },

  draw() {
    const { canvas, ctx, image, radius } = this;
    const centerX = canvas.width / 2;
    const centerY = canvas.height / 2;

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
    }

    ctx.strokeStyle = "#ff0000";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(centerX, centerY, radius, 0, Math.PI * 2);
    ctx.stroke();

    ctx.fillStyle = "#ff0000";
    ctx.beginPath();
    ctx.arc(centerX + radius, centerY, 6, 0, Math.PI * 2);
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
    const centerX = this.canvas.width / 2;
    const centerY = this.canvas.height / 2;

    const distFromCenter = Math.sqrt((pos.x - centerX) ** 2 + (pos.y - centerY) ** 2);
    const distToEdge = Math.abs(distFromCenter - this.radius);

    if (distToEdge < 15) {
      this.dragging = true;
    }
  },

  onMouseMove(e) {
    if (!this.dragging) return;

    const pos = this.getCanvasCoords(e);
    const centerX = this.canvas.width / 2;
    const centerY = this.canvas.height / 2;

    const dist = Math.sqrt((pos.x - centerX) ** 2 + (pos.y - centerY) ** 2);
    this.radius = Math.max(5, Math.round(dist));

    this.draw();
    this.pushRadiusUpdate();
  },

  onMouseUp() {
    if (this.dragging) {
      this.dragging = false;
      this.pushRadiusUpdate();
    }
  },

  pushRadiusUpdate() {
    this.pushEvent("update_center_filter", { radius: this.radius });
  },

  destroyed() {
    this.canvas.removeEventListener("mousedown", this.onMouseDown);
    this.canvas.removeEventListener("mousemove", this.onMouseMove);
    this.canvas.removeEventListener("mouseup", this.onMouseUp);
    this.canvas.removeEventListener("mouseleave", this.onMouseUp);
  }
};

export default DftCanvas;
