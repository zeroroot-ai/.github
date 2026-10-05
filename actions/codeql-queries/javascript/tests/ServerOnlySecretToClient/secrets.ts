import "server-only";

// A server-only module. Nothing it exports may reach the client.
export const apiKey = process.env.API_KEY;
export const region = "eu-west-1";
