import socket from "../user_socket";

const POLL_INTERVAL = 50;
const BUTTON_REPEAT_DELAY = 150;
const DPAD_REPEAT_DELAY = 100;
const STICK_REPEAT_DELAY = 50;
const STICK_DEADZONE = 0.3;
const STICK_HIGH_THRESHOLD = 0.7;

const BUTTON = {
  A: 1,
  L: 4,
  R: 5,
  ZL: 6,
  ZR: 7,
  PLUS: 9,
  DPAD_UP: 12,
  DPAD_DOWN: 13,
  DPAD_LEFT: 14,
  DPAD_RIGHT: 15,
};

const AXIS = {
  LEFT_X: 0,
  LEFT_Y: 1,
  RIGHT_X: 2,
  RIGHT_Y: 3,
};

const Gamepad = {
  mounted() {
    this.channel = socket.channel("gamepad:control", {});
    this.channel
      .join()
      .receive("ok", () => console.log("Gamepad channel joined"))
      .receive("error", (resp) =>
        console.error("Unable to join gamepad channel", resp)
      );

    this.pollInterval = null;
    this.lastInputTime = {};
    this.lastButtonState = {};
    this.lastAxisState = {};

    window.addEventListener("gamepadconnected", (e) => {
      console.log("Gamepad connected:", e.gamepad.id);
      console.log("Gamepad details:", e.gamepad);
      this.startPolling();
    });

    window.addEventListener("gamepaddisconnected", () => {
      console.log("Gamepad disconnected");
      this.stopPolling();
    });

    const gamepads = navigator.getGamepads();
    console.log("Checking for existing gamepads:", gamepads);
    for (let i = 0; i < gamepads.length; i++) {
      if (gamepads[i]) {
        console.log("Found existing gamepad:", gamepads[i].id);
        this.startPolling();
        break;
      }
    }

    console.log("Gamepad hook mounted. Press any button on your gamepad to activate it.");
  },

  destroyed() {
    this.stopPolling();
    this.channel.leave();
  },

  startPolling() {
    if (this.pollInterval) return;
    this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL);
  },

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  },

  poll() {
    const gamepad = navigator.getGamepads()[0];
    if (!gamepad) return;

    const now = Date.now();

    this.handleButton(now, "zl", gamepad.buttons[BUTTON.ZL], () => {
      this.channel.push("move_axis", { axis: "z", delta: -10 });
    });

    this.handleButton(now, "zr", gamepad.buttons[BUTTON.ZR], () => {
      this.channel.push("move_axis", { axis: "z", delta: 10 });
    });

    this.handleButton(
      now,
      "plus",
      gamepad.buttons[BUTTON.PLUS],
      () => {
        this.channel.push("toggle_liveview", {});
      },
      500
    );

    this.handleButton(
      now,
      "a",
      gamepad.buttons[BUTTON.A],
      () => {
        this.channel.push("capture", {});
      },
      500
    );

    this.handleButton(
      now,
      "dpad_up",
      gamepad.buttons[BUTTON.DPAD_UP],
      () => {
        this.channel.push("adjust_outline_position", { dx: 0, dy: -5 });
        window.dispatchEvent(new CustomEvent("outline-adjusted"));
      },
      DPAD_REPEAT_DELAY
    );

    this.handleButton(
      now,
      "dpad_down",
      gamepad.buttons[BUTTON.DPAD_DOWN],
      () => {
        this.channel.push("adjust_outline_position", { dx: 0, dy: 5 });
        window.dispatchEvent(new CustomEvent("outline-adjusted"));
      },
      DPAD_REPEAT_DELAY
    );

    this.handleButton(
      now,
      "dpad_left",
      gamepad.buttons[BUTTON.DPAD_LEFT],
      () => {
        this.channel.push("adjust_outline_position", { dx: -5, dy: 0 });
        window.dispatchEvent(new CustomEvent("outline-adjusted"));
      },
      DPAD_REPEAT_DELAY
    );

    this.handleButton(
      now,
      "dpad_right",
      gamepad.buttons[BUTTON.DPAD_RIGHT],
      () => {
        this.channel.push("adjust_outline_position", { dx: 5, dy: 0 });
        window.dispatchEvent(new CustomEvent("outline-adjusted"));
      },
      DPAD_REPEAT_DELAY
    );

    this.handleButton(
      now,
      "l",
      gamepad.buttons[BUTTON.L],
      () => {
        this.channel.push("adjust_outline_radius", { delta: -5 });
        window.dispatchEvent(new CustomEvent("outline-adjusted"));
      },
      BUTTON_REPEAT_DELAY
    );

    this.handleButton(
      now,
      "r",
      gamepad.buttons[BUTTON.R],
      () => {
        this.channel.push("adjust_outline_radius", { delta: 5 });
        window.dispatchEvent(new CustomEvent("outline-adjusted"));
      },
      BUTTON_REPEAT_DELAY
    );

    this.handleStickAxis(now, "left_x", gamepad.axes[AXIS.LEFT_X], (delta) => {
      this.channel.push("move_axis", { axis: "x", delta });
    });

    this.handleStickAxis(now, "left_y", gamepad.axes[AXIS.LEFT_Y], (delta) => {
      this.channel.push("move_axis", { axis: "y", delta });
    });

    this.handleStickAxis(
      now,
      "right_y",
      gamepad.axes[AXIS.RIGHT_Y],
      (delta) => {
        const filterDelta = delta > 0 ? 1 : -1;
        this.channel.push("adjust_center_filter_radius", {
          delta: filterDelta,
        });
        window.dispatchEvent(new CustomEvent("center-filter-adjusted"));
      }
    );
  },

  handleButton(now, name, button, action, repeatDelay = BUTTON_REPEAT_DELAY) {
    const pressed = button.pressed;
    const wasPressed = this.lastButtonState[name] || false;
    const lastTime = this.lastInputTime[name] || 0;

    if (pressed && (!wasPressed || now - lastTime >= repeatDelay)) {
      action();
      this.lastInputTime[name] = now;
    }

    this.lastButtonState[name] = pressed;
  },

  handleStickAxis(now, name, value, action) {
    const lastValue = this.lastAxisState[name] || 0;
    const lastTime = this.lastInputTime[name] || 0;

    let zone = "dead";
    if (Math.abs(value) > STICK_HIGH_THRESHOLD) {
      zone = value > 0 ? "high_pos" : "high_neg";
    } else if (Math.abs(value) > STICK_DEADZONE) {
      zone = value > 0 ? "low_pos" : "low_neg";
    }

    let lastZone = "dead";
    if (Math.abs(lastValue) > STICK_HIGH_THRESHOLD) {
      lastZone = lastValue > 0 ? "high_pos" : "high_neg";
    } else if (Math.abs(lastValue) > STICK_DEADZONE) {
      lastZone = lastValue > 0 ? "low_pos" : "low_neg";
    }

    const zoneChanged = zone !== lastZone;
    const canRepeat = now - lastTime >= STICK_REPEAT_DELAY;

    if (zone !== "dead" && (zoneChanged || canRepeat)) {
      const isHigh = zone.startsWith("high");
      const delta = isHigh ? 100 : 10;
      const sign = value > 0 ? 1 : -1;
      action(delta * sign);
      this.lastInputTime[name] = now;
    }

    this.lastAxisState[name] = value;
  },
};

export default Gamepad;
