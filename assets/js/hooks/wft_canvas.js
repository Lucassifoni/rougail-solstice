const WftCanvas = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.image = new Image();
    this.imageLoaded = false;

    this.image.onload = () => {
      this.imageLoaded = true;
      this.draw();
    };

    this.image.onerror = (e) => {
      console.error("[WftCanvas] image load error", e);
    };

    this.handleEvent("update_wft_image", ({ src }) => {
      if (src) {
        console.log("[WftCanvas] received update_wft_image", src);
        this.image.src = src + "?v=" + Date.now();
      }
    });
  },

  draw() {
    const { canvas, ctx, image } = this;

    ctx.fillStyle = "#282828";
    ctx.fillRect(0, 0, canvas.width, canvas.height);

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
  }
};

export default WftCanvas;
