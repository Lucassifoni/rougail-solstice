const Jog = {
  mounted() {
    const start = () => {
      this.pushEvent("drive_motor", {
        axis: this.el.dataset.axis,
        direction: this.el.dataset.direction,
        speed: this.el.dataset.speed,
      });
    };

    const stop = () => {
      this.pushEvent("stop_motor", {});
    };

    this.el.addEventListener("mousedown", start);
    this.el.addEventListener("mouseup", stop);
    this.el.addEventListener("mouseleave", stop);
    this.el.addEventListener("touchstart", (e) => {
      e.preventDefault();
      start();
    });
    this.el.addEventListener("touchend", stop);
    this.el.addEventListener("touchcancel", stop);
  },
};

export default Jog;
