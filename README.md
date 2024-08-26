<img align="right" height="296px" src="https://github.com/user-attachments/assets/b127f53f-c1f8-43dc-9a2e-36e42562f17c" alt="Zoooooom!" />
<h1 align="left">Zune</h1>
<div align="left">
    <a href="https://github.com/Scythe-Technology/Zune/releases" target="_blank"><img src="https://img.shields.io/badge/x64,_arm64-Linux?style=flat-square&logo=linux&logoColor=white&label=Linux&color=orange"/>
    <img src="https://img.shields.io/badge/x64,_arm64-macOs?style=flat-square&logo=apple&label=macOs&color=white"/>
    <img src="https://img.shields.io/badge/x64,_arm64-windows?style=flat-square&label=Windows&color=blue"/></a>
</div>

<br/>

<p align="left">
Zune is a <a href="https://luau.org/">Luau</a> runtime built with Zig, inspired by <a href="https://lune-org.github.io/docs">Lune</a>, similar to <a href="https://nodejs.org">Node</a>, or <a href="https://bun.sh">Bun</a>.
</p>

## Features
- **Comprehensive API**: Includes fully featured APIs for filesystem operations, networking, and standard I/O.
- **Rich Standard Library**: A rich standard library with utilities for basic needs, reducing the need for external dependencies.
- **Cross-Platform Compatibility**: Fully compatible with **Linux**, **macOS**, and **Windows**, ensuring broad usability across different operating systems.
- **Static Executable/Minimal Dependency**: A single statically linked executable for linux, or minimal dependency for macos and windows, ensures easy distribution and installation, without the need of many dependencies.
- **Inspired by Lune**: Inspiration from Lune, providing a familiar environment for developers who have used Lune before.

## Installation
You can get started with Zune by installing it via a package manager, releases, or by building it from source.

### From Package Manager
- **None, yet.**

### From Releases
1. Head over to [Releases](https://github.com/Scythe-Technology/Zune/releases).
2. Download for your system's architecture and os.
3. Unzip.
4. Run.

### From Source
Requirements:
- [Zig](https://ziglang.org/).

To build Zune from source:
1. Clone the repository:
```sh
git clone https://github.com/Scythe-Technology/Zune.git
cd zune
```
2. Compile
```sh
zig build -Doptimize=ReleaseSafe
```
3. Use
```sh
./zig-out/bin/zune version
```
From this point, you can add the binary to your path.

# Roadmap
For more information on the future of Zune, join the discord server and check the `roadmap` post.

# Contributing
Read [CONTRIBUTING.md](https://github.com/Scythe-Technology/Zune/blob/master/CONTRIBUTING.md).
