import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Served from a project page, so assets need the repository in their path.
  base: "/Zimacs/",
});
