defmodule RougailSolstice.Sessions.Topics do
  @moduledoc """
  PubSub topic helpers for session-scoped and global topics.
  """

  @pubsub RougailSolstice.PubSub

  def robot(nil), do: "robot:state"
  def robot(session_id), do: "session:#{session_id}:robot:state"

  def interferometry(nil), do: "interferometry:state"
  def interferometry(session_id), do: "session:#{session_id}:interferometry:state"

  def outline(nil), do: "outline:state"
  def outline(session_id), do: "session:#{session_id}:outline:state"

  def session_events, do: "sessions:events"

  def subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end
end
