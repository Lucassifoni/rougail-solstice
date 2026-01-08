import { Socket } from "phoenix";

const socket = new Socket("/socket", { params: {} });
socket.connect();

export default socket;
