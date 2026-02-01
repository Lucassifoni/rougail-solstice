import socket from "../user_socket";

const POLL_INTERVAL = 50;
const BUTTON_REPEAT_DELAY = 150;
const DPAD_REPEAT_DELAY = 100;
const STICK_DEADZONE = 0.15;

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

const MAX_SPEED = 75;
const Z_DRIVE_SPEED = MAX_SPEED;

const Gamepad = {
  mounted() {
    const sessionId = this.el.dataset.sessionId;
    if (!sessionId) {
      console.error("Gamepad hook: no session ID provided");
      return;
    }

    this.channel = socket.channel(`gamepad:control:${sessionId}`, {});
    this.channel
      .join()
      .receive("ok", () =>
        console.log(`Gamepad channel joined for session ${sessionId}`)
      )
      .receive("error", (resp) =>
        console.error("Unable to join gamepad channel", resp)
      );

    this.pollInterval = null;
    this.lastInputTime = {};
    this.lastButtonState = {};
    this.lastAxisState = {};
    this.activeDriveAxes = new Set();

    window.addEventListener("gamepadconnected", (e) => {
      console.log("Gamepad connected:", e.gamepad.id);
      this.startPolling();
    });

    window.addEventListener("gamepaddisconnected", () => {
      console.log("Gamepad disconnected");
      this.stopAllMotors();
      this.stopPolling();
    });

    const gamepads = navigator.getGamepads();
    for (let i = 0; i < gamepads.length; i++) {
      if (gamepads[i]) {
        this.startPolling();
        break;
      }
    }
  },

  destroyed() {
    this.stopAllMotors();
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

  stopAllMotors() {
    if (this.activeDriveAxes.size > 0) {
      this.channel.push("stop_motor", {});
      this.activeDriveAxes.clear();
    }
  },

  poll() {
    const gamepad = navigator.getGamepads()[0];
    if (!gamepad) return;

    const now = Date.now();

    this.handleMotorButton(now, "zl", gamepad.buttons[BUTTON.ZL], "z", "negative");
    this.handleMotorButton(now, "zr", gamepad.buttons[BUTTON.ZR], "z", "positive");

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

    this.handleMotorStick("x", gamepad.axes[AXIS.LEFT_X]);
    this.handleMotorStick("y", gamepad.axes[AXIS.LEFT_Y]);

    this.handleStickAxis(now, "right_y", gamepad.axes[AXIS.RIGHT_Y], (delta) => {
      const filterDelta = delta > 0 ? 1 : -1;
      this.channel.push("adjust_center_filter_radius", {
        delta: filterDelta,
      });
      window.dispatchEvent(new CustomEvent("center-filter-adjusted"));
    });
  },

  handleMotorButton(now, name, button, axis, direction) {
    const pressed = button.pressed;
    const wasPressed = this.lastButtonState[name] || false;

    if (pressed && !wasPressed) {
      this.channel.push("drive_motor", {
        axis,
        direction,
        speed: Z_DRIVE_SPEED,
      });
      this.activeDriveAxes.add(axis);
    } else if (!pressed && wasPressed) {
      this.channel.push("stop_motor", {});
      this.activeDriveAxes.delete(axis);
    }

    this.lastButtonState[name] = pressed;
  },

  handleMotorStick(axis, value) {
    const wasActive = this.activeDriveAxes.has(axis);
    const inDeadzone = Math.abs(value) < STICK_DEADZONE;

    if (inDeadzone) {
      if (wasActive) {
        this.channel.push("stop_motor", {});
        this.activeDriveAxes.delete(axis);
      }
      return;
    }

    const direction = value > 0 ? "positive" : "negative";
    const speed = Math.min(MAX_SPEED, Math.round(Math.abs(value) * MAX_SPEED));

    this.channel.push("drive_motor", { axis, direction, speed });
    this.activeDriveAxes.add(axis);
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
    const STICK_HIGH_THRESHOLD = 0.7;
    const STICK_REPEAT_DELAY = 50;
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
