# Plan: Refactor RobotLive to be 100% Session-Aware

## Goal
Replace the dual LiveView approach (singleton `RobotLive` + session-aware `SessionRobotLive`) with a single `RobotLive` that is fully session-aware. All robot control goes through sessions.

## Current State
- `RobotLive` (968 lines): Full-featured, uses singleton servers via `Commands` module
- `SessionRobotLive` (523 lines): Partial port, missing many features
- `Commands` module: Already accepts optional server parameters, defaults to singletons
- Session infrastructure: `SessionManager`, `SessionSupervisor`, `Topics` all working
- Image storage: Session-scoped `ImageStore` with `/sessions/:id/images/:key` URLs

## Architecture Decision
**Remove singleton servers entirely.** All robot control requires a session. The home page (`/`) shows session list; users open a session to access robot control.

---

## Phase 1: Update RobotLive to Accept Session Context

### 1.1 Change mount to require session_id parameter
**File:** `lib/rougail_solstice_web/live/robot_live.ex`

```elixir
# Before
def mount(_params, _session, socket) do
  Server.subscribe()
  InterfServer.subscribe()
  ...
  state = Server.get_state()

# After
def mount(%{"session_id" => session_id_str}, _session, socket) do
  session_id = String.to_integer(session_id_str)

  case SessionManager.get_session(session_id) do
    {:ok, session_info} ->
      servers = SessionManager.session_servers(session_id)

      if connected?(socket) do
        Topics.subscribe(Topics.robot(session_id))
        Topics.subscribe(Topics.interferometry(session_id))
        Topics.subscribe(Topics.outline(session_id))
      end

      # Store servers in assigns for use in event handlers
      socket
      |> assign(:session_id, session_id)
      |> assign(:session_info, session_info)
      |> assign(:servers, servers)
      |> assign(:state, RobotServer.get_state(servers.robot))
      |> assign(:interf_state, InterfServer.get_state(servers.interferometry))
      |> assign(:outline_state, OutlineServer.get_state(servers.outline))
      ...

    {:error, :not_found} ->
      socket
      |> put_flash(:error, "Session not found")
      |> push_navigate(to: ~p"/")
  end
```

### 1.2 Update all event handlers to use session servers
Replace `Commands.function()` with `Commands.function(server, ...)` using `socket.assigns.servers`.

Example:
```elixir
# Before
def handle_event("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
  case Commands.move_axis(axis, delta) do

# After
def handle_event("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
  case Commands.move_axis(socket.assigns.servers.robot, axis, delta) do
```

### 1.3 Update handle_info for PubSub messages
Replace singleton message patterns with session-scoped ones:

```elixir
# Before
def handle_info({:robot_state_changed, state}, socket) do

# After (same pattern, but subscribed to session topic)
def handle_info({:robot_state_changed, state}, socket) do
```

### 1.4 Update image URLs to use session-scoped paths
Anywhere images are referenced, ensure they use `/sessions/:id/images/:key` format.

---

## Phase 2: Update Router

### 2.1 Remove legacy /robot route, update session route
**File:** `lib/rougail_solstice_web/router.ex`

```elixir
# Before
live "/sessions/:session_id/robot", SessionRobotLive
live "/robot", RobotLive

# After
live "/sessions/:session_id/robot", RobotLive
# Remove standalone /robot route
```

---

## Phase 3: Remove Legacy Singleton Infrastructure

### 3.1 Remove legacy singleton servers from application.ex
**File:** `lib/rougail_solstice/application.ex`

```elixir
# Before
defp legacy_singleton_children do
  [
    RougailSolstice.ImageStore,
    RougailSolstice.Robot.Server,
    RougailSolstice.Outline.Server,
    RougailSolstice.Interferometry.Server
  ]
end

# After
defp legacy_singleton_children do
  []  # Or remove the function entirely
end
```

### 3.2 Update Commands module defaults (optional)
Either:
- Remove default server parameters (force explicit passing)
- Or keep defaults for potential CLI/testing use

### 3.3 Remove SessionRobotLive
**File:** Delete `lib/rougail_solstice_web/live/session_robot_live.ex`

---

## Phase 4: Fix Remaining Session-Aware Issues

### 4.1 Outline detection application
Ensure `OutlineServer` applies detected outlines to `InterfServer`:
- Check `OutlineServer.maybe_apply_outline/2` uses correct servers
- Verify PubSub topics for outline updates

### 4.2 Gamepad channel session awareness
**File:** `lib/rougail_solstice_web/channels/gamepad_channel.ex` (if exists)

Update to accept session_id and use session-scoped servers.

### 4.3 DFT/WFT preview URLs
Ensure all generated image URLs use `ImageStore.session_url(session_id, key)`.

---

## Phase 5: Testing Checklist

### Manual Testing
- [ ] Open session from home page
- [ ] Axis controls work (X, Y, Z movement)
- [ ] Camera lock/unlock works
- [ ] Start/stop liveview shows preview
- [ ] Preview updates in real-time
- [ ] Outline circle dragging works
- [ ] Auto-outline detection works and applies
- [ ] DFT preview generates and displays
- [ ] Center filter radius adjustment works
- [ ] Capture full shot works
- [ ] WFT preview generates after analysis
- [ ] Analysis results display
- [ ] Gamepad controls work (if applicable)
- [ ] Multiple sessions can run independently
- [ ] Closing session cleans up properly

### Files to Modify
1. `lib/rougail_solstice_web/live/robot_live.ex` - Main refactor
2. `lib/rougail_solstice_web/router.ex` - Route updates
3. `lib/rougail_solstice/application.ex` - Remove singletons
4. `lib/rougail_solstice_web/channels/gamepad_channel.ex` - Session awareness (if exists)

### Files to Delete
1. `lib/rougail_solstice_web/live/session_robot_live.ex`

---

## Implementation Order

1. **Phase 1.1-1.2**: Update mount and event handlers (biggest change)
2. **Phase 1.3-1.4**: Update handle_info and image URLs
3. **Phase 2**: Update router
4. **Phase 4.1-4.3**: Fix outline, gamepad, image URLs
5. **Test thoroughly**
6. **Phase 3**: Remove legacy infrastructure (after confirming everything works)
7. **Delete SessionRobotLive**

---

## Rollback Plan
If issues arise:
- Keep `SessionRobotLive` as backup
- Restore legacy singleton children in application.ex
- Restore `/robot` route

---

## Notes

### Commands Module
The `Commands` module is well-designed - it already accepts optional server parameters. We just need to pass them explicitly from RobotLive.

### PubSub Topics
Session-scoped topics follow pattern: `"session:#{session_id}:robot:state"`
Use `Topics.robot(session_id)`, `Topics.interferometry(session_id)`, `Topics.outline(session_id)`

### Image URLs
- Session images: `/sessions/:session_id/images/:key`
- Use `ImageStore.session_url(session_id, key)` to generate
- `extract_image_key/1` helper parses both formats

### Sidecar Workers
Already session-scoped via `Supervisor.preview_worker(session_id)`
CLI functions accept `session_id:` option
