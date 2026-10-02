<!-- SPDX-License-Identifier: MIT -->
# oai-macos-arm64

A reproducible kit for building and running the OpenAirInterface
([Duranta](https://github.com/duranta-project/openairinterface5g)) 5G gNB
and nrUE natively on macOS with Apple Silicon, validated with a 5G SA attach
of the OAI nrUE over the RF simulator against an Open5GS 5GC, with a PDU
session and a bidirectional ping, all on one machine.

OpenAirInterface is a 5G RAN and UE stack written for Linux. This repository
carries no OpenAirInterface source. It carries 26 numbered patches against the
upstream tag `2026.w39` (commit `29d5fa7d`, OAI version 2.4.0), the gNB and UE
configuration of the loopback test, two host-side scripts, the recipe for the
four tools the port needs, and the Darwin facts that are not in any manual.
Clone upstream, `git am` the patches, build.

## What was validated

Platform: macOS 26 (Darwin 25.6) on Apple M-series, Apple clang 21, Homebrew,
CMake 4.4, Ninja 1.13, OpenAirInterface 2026.w39, Open5GS v2.8.0.

- Build: `nr-softmodem`, `nr-uesoftmodem` and the modules they load at run
  time (`params_libconfig`, `params_yaml`, `rfsimulator`, `ldpc`, `dfts`)
  configure, compile and link. The PHY compiles through SIMDe on Apple
  clang without a change to SIMDe. The thread pool unit test passes. The
  rest of `tests/` and the PHY simulators were not built.
- NG Setup: the gNB opens a one-to-one SCTP association to the AMF through
  the shim (UDP encapsulation 9900 to 9899) and completes NG Setup in 2.4 ms.
- Registration: the nrUE over the RF simulator finds the cell (band n78,
  SSB ARFCN 641280, 106 PRB, 30 kHz), completes RACH, RRC Setup, 5G-AKA,
  Security Mode and Registration; the AMF logs `Registration complete` for
  the test subscriber 47 ms after the Initial UE Message.
- PDU Session: the UE receives IP 10.45.0.6 from the SMF and puts it on a
  utun; the gNB completes the PDU Session Resource Setup and
  configures the N3 GTP-U tunnel to the UPF (7.4 ms from request to response).
- User plane: `run-5gsa-oai-root.sh` sets the crossed host routes and pings
  both ways, UE to gateway and gateway to UE, 4 of 4 packets each way, with
  a round trip of 4 ms on average; 18 more pings during a GTP-U capture
  showed every ICMP request and reply inside the tunnel. A session of 11
  minutes ran with zero HARQ errors in both directions on the simulator.

Nothing is transmitted at any point: both ends exchange IQ samples over TCP
on localhost. No RF hardware was used with OpenAirInterface in this work;
the USRP driver was not built.

The scripts in `config/` were rewritten after the validation run to take
their paths from the environment and to carry English messages. They passed
`bash -n` and the copy test; the functional run was made with the unscrubbed
versions on the same tree. Logic and commands are the same.

## Quick start

### 1. Dependencies

```
brew install cmake ninja libconfig openssl yaml-cpp bison autoconf automake libtool tmux
```

Four pieces are built from source into one prefix (`$PREFIX` below). None
is in Homebrew in the form OpenAirInterface needs.

- asn1c, the fork and commit OpenAirInterface pins (the current head of that
  fork generates a different CHOICE layout and the RRC code does not compile
  against it):

  ```
  git clone https://github.com/mouse07410/asn1c && cd asn1c
  git checkout 940dd5fa9f3917913fd487b13dfddfacd0ded06e
  PATH="/opt/homebrew/opt/bison/bin:$PATH" LIBTOOLIZE=glibtoolize autoreconf -iv
  mkdir build && cd build && CFLAGS="-O2 -fno-strict-aliasing" ../configure --prefix="$PREFIX" && make -j8 && make install
  ```

  Apple's bison 2.3 is too old; the Homebrew one must be first in PATH.
- SIMDe, headers only, at the commit OpenAirInterface pins. The tree is not
  vendored upstream and the build does not look for it; it has to be on the
  include path:

  ```
  git clone https://github.com/simd-everywhere/simde-no-tests && cd simde-no-tests
  git checkout 1c68d9ad60bf63f3fb527c4ee3b2319d828ffcc6
  mkdir -p "$PREFIX/include/simde" && rsync -a --exclude .git ./ "$PREFIX/include/simde/"
  ```
- [epoll-shim](https://github.com/jiixyj/epoll-shim): epoll, eventfd and
  timerfd over kqueue. Commit `18159584` was used; its test suite passes on
  macOS 26 except three assertions on the Linux size of `struct epoll_event`
  (16 bytes on arm64, 12 on Linux; no effect inside one process).

  ```
  git clone https://github.com/jiixyj/epoll-shim && cd epoll-shim
  cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -S . -B build
  ninja -C build install
  ```

  The CMake package lands in `$PREFIX/lib/cmake/epoll-shim`, which is how
  patch 010 finds it.
- [libsctp-compat-macos-arm64](https://github.com/AndreiGosman/libsctp-compat-macos-arm64)
  v0.4.1 or later: the Linux lksctp API over usrsctp with UDP encapsulation
  (RFC 6951). Install it into the same prefix; OpenAirInterface finds it
  through `netinet/sctp.h` and `libsctp.dylib` under `CMAKE_PREFIX_PATH`.
  Version 0.4.1 is the one that accepts the 8-byte `SCTP_EVENTS`
  subscription OpenAirInterface sends.

The 5GC comes from [open5gs-macos-arm64](https://github.com/AndreiGosman/open5gs-macos-arm64):
its 5GC configuration set and `lo0-aliases-5gc.sh` are what
`start-5gc-user.sh` starts. Render that set into `$CONFDIR/open5gs-5gc`.

### 2. Build OpenAirInterface with the patches

```
export PREFIX="$HOME/oai-lab/local"
git clone https://github.com/AndreiGosman/oai-macos-arm64.git
git clone --branch 2026.w39 https://github.com/duranta-project/openairinterface5g.git
cd openairinterface5g
git am ../oai-macos-arm64/patches/*.patch
mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DASN1C_EXEC="$PREFIX/bin/asn1c" -DT_TRACER=OFF \
  -DCMAKE_C_FLAGS="-I$PREFIX/include" -DCMAKE_CXX_FLAGS="-I$PREFIX/include" -S .. -B .
ninja nr-softmodem nr-uesoftmodem params_libconfig params_yaml rfsimulator ldpc dfts
```

- The modules are separate targets. A fresh build directory with only the
  two executables built fails at start with `dlopen(libparams_libconfig.so)`.
- `-DT_TRACER=OFF` keeps the T tracer out; it was not ported or tested.
- After any patch that touches CMake, `rm -rf build` before reconfiguring.
- `-Werror` is off upstream. The build emits a few hundred warnings, almost
  all `-Wformat` on `uint64_t` (`long long` on Darwin, `long` on glibc) and
  the deprecated `sprintf` of the macOS SDK. None is a port issue.
- Do not build `build_oai` with `-I`: it runs `apt install`.

### 3. Copy the configuration

`config/gnb.conf` and `config/ue.conf` carry no placeholder. `render.sh`
copies them into the layout the attach script expects:

```
export CONFDIR="$HOME/oai-lab/config" LOGDIR="$HOME/oai-lab/logs"
oai-macos-arm64/config/render.sh "$CONFDIR"
```

That writes `$CONFDIR/oai-5gsa/gnb.conf` and `$CONFDIR/oai-5gsa/ue.conf`.
The 5GC set from the open5gs kit goes to `$CONFDIR/open5gs-5gc` with that
kit's own `render.sh`.

### 4. Run the 5GC

```
sudo "$CONFDIR/open5gs-5gc/lo0-aliases-5gc.sh"                           # once per boot
PREFIX="$PREFIX" CONFDIR="$CONFDIR" LOGDIR="$LOGDIR" MONGODB="$HOME/oai-lab/mongodb" \
  oai-macos-arm64/config/start-5gc-user.sh                               # mongod + 10 NFs, no root
sudo "$PREFIX/bin/open5gs-upfd" -c "$CONFDIR/open5gs-5gc/upf.yaml"       # root: utun, own terminal
```

The subscriber is the Open5GS test subscriber (IMSI 001010000000001, DNN
`internet`, SST 1, the K and OPc from the Open5GS documentation); add it
with `open5gs-dbctl` as the open5gs kit describes.

### 5. gNB alone

```
cd openairinterface5g/build
LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900 LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899 \
  ./nr-softmodem -O "$CONFDIR/oai-5gsa/gnb.conf" --rfsim
```

Expected within two seconds: `Send NGSetupRequest to AMF`, `Received
NGSetupResponse from AMF`, `Running as server waiting opposite rfsimulators
to connect`. The AMF logs `Number of gNBs is now 1`. Setting
`LIBSCTP_COMPAT_DEBUG=1` prints the shim's socket lines. `--sa` is not an
option any more at this tag; SA is the default.

### 6. Attach test

```
sudo PREFIX="$PREFIX" CONFDIR="$CONFDIR" LOGDIR="$LOGDIR" \
     BUILD="$PWD/openairinterface5g/build" oai-macos-arm64/config/run-5gsa-oai-root.sh
```

The script stops a leftover nrUE and gNB with SIGINT, restarts the gNB as
`$SUDO_USER` through the shim, waits for NG Setup, starts the nrUE as root in
a tmux session, waits for `Received PDU Session Establishment Accept`, sets
the UPF utun destination to the UE address, installs the crossed host routes
and pings both ways. Stop the UE with `tmux send-keys -t 5gsa-oai C-c`.

To run the nrUE by hand (root, for the utun):

```
sudo ./nr-uesoftmodem -O "$CONFDIR/oai-5gsa/ue.conf" --rfsim '--rfsimulator.[0].serveraddr' 127.0.0.1 \
  -r 106 --numerology 1 --band 78 -C 3619200000
```

The quotes around the rfsimulator option matter in zsh, which otherwise
treats the brackets as a glob.

## The 26 patches

All are on the `darwin-arm64` lineage over `2026.w39`; the series replays
on the clean tag (80 files, 1076 insertions, 121 deletions, 2 new files:
`common/utils/darwin_compat.h` and `common/utils/oai_sem.h`). Each commit
message states the symptom, the cause and the choice made. Grouped by what
they do:

Build system (001, 002, 004, 005, 010, 014, 023). CMake sees `arm64` on
Darwin where Linux says `aarch64`, and stops with an error on anything
else. ld64 is not GNU ld: no `--start-group`, no `--whole-archive`, no
`librt` or `libgcc` to link. The modules OpenAirInterface loads with
`dlopen()` call back into the executable, which ld64 refuses unless told to
resolve those symbols at load time. pkg-config results are used as bare
library names and without their include directories, which only works where
the libraries live in the compiler's default paths. epoll-shim is linked
everywhere, because its `sys/epoll.h` redefines `close()` as a macro and the
inter-task interface header includes it from 143 translation units. And 023,
the one to know: ld64 binds each undefined symbol to the first library on
the link line that exports it, so the SCTP shim must come ahead of the
objects or `socket()` goes to the kernel and the gNB reports `Protocol not
supported`.

Darwin compatibility layer (007, 013, 016, 024). `common/utils/darwin_compat.h`,
empty elsewhere, provides pthread barriers, `clock_nanosleep()` with
`TIMER_ABSTIME`, `recvmmsg()` and `sendmmsg()`, `sysinfo()`,
`pthread_mutex_timedlock()`, `get_nprocs()`, the `cpu_set_t` type with the
affinity calls as stubs, the two-argument `pthread_setname_np()`,
`explicit_bzero()` and the `htobe` family; `common/utils/oai_sem.h` is a
counting semaphore (`sem_init()` returns ENOSYS on Darwin). 024 gives every
thread of `threadCreate()` an 8 MB stack: Darwin's default for secondary
threads is 512 KB and the L1 receive thread overflows it at the first slot.

glibc-only interfaces (003, 008, 009, 011, 012, 015, 018, 019, 020). The
headers `malloc.h`, `endian.h`, `asm/byteorder.h`, `sys/sysinfo.h`,
`linux/*.h`, `syscall.h`, `error.h`, `netinet/ether.h`; `memalign()`,
`srand48_r()`, `syscall(__NR_gettid)`, `SCHED_IDLE`, `SIGRTMIN`,
`CLOCK_BOOTTIME`, the Linux capability syscall; and 020, the one that
crashed every executable at start: the configuration loader splits its
source string with `sscanf()` and the allocating `%m` conversion, which only
glibc has.

Darwin libc and resolver differences (017, 022, 025). `HOST_NAME_MAX` is
not POSIX; `msghdr::msg_iovlen` is `int` on Darwin; a file with `using
namespace std` resolves `bind(sd, addr, len)` to `std::bind` under libc++;
the Darwin resolver answers "Bad hints" to `getaddrinfo()` with
`IPPROTO_SCTP`; and `aligned_alloc(4, n)` returns NULL on Darwin (alignment
below the pointer size), which dereferenced NULL at the first Msg4.

PHY (006). One contract: `_mm_slli_epi32()` takes an immediate count, and
five call sites pass a run-time value. x86 compilers tolerate it; on NEON
through SIMDe the immediate form needs a constant, which GCC checks after
inlining and clang when parsing. The register-count form `_mm_sll_epi32()`
has the same semantics for every count. This was the only SIMD change; the
rest of the PHY compiled through SIMDe as it is.

UE tunnel (021, 026). `tuntap_if.c` was written on the Linux tun driver and
netlink. On Darwin the UE opens a utun through the kernel control socket,
keeps a table from the name OpenAirInterface generates to the `utunN` the
kernel assigns, configures the address with `SIOCAIFADDR` (destination in
the broadaddr slot), and adds or strips the 4-byte address family header
utun puts in front of every packet in `tuntap_read()` and `tuntap_write()`.

Several of these are not Darwin-specific and are candidates for upstream:
004, 006, 014, 020, 022, 025. None has been submitted yet.

## Darwin behaviours to know

1. NGAP must bind to the real 127.0.0.1, never to an `lo0` alias. The
   shipped `gnb.conf` sets `amf_ip_address`, `GNB_IPV4_ADDRESS_FOR_NG_AMF`
   and `GNB_IPV4_ADDRESS_FOR_NGU` to it.
2. One UDP encapsulation port per process. The Open5GS AMF runs native
   usrsctp on UDP 9899. The gNB's shim takes `LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900`
   and `LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899`.
3. OpenAirInterface subscribes to SCTP notifications with `SCTP_EVENTS` and a
   length of 8 bytes. lksctp accepts that, usrsctp wants the full structure;
   libsctp-compat 0.4.1 widens it. With 0.4.0 the gNB asserts on its first
   socket.
4. The RF simulator is a TCP server in the gNB on port 4043 and is not
   real time by design. Do not capture that port with tcpdump: it is the IQ
   stream, hundreds of megabytes per second. Capture `udp port 9899 or udp
   port 9900` for NGAP and `udp port 2152` for GTP-U.
5. Root processes. The UPF and the nrUE need root for the utun; the gNB
   does not. Stop root processes with SIGINT; the nrUE deregisters cleanly
   and the AMF logs `UEContextReleaseCommand` with cause `deregister`.
6. The UPF utun has a self point-to-point destination (`10.45.0.1 -->
   10.45.0.1`). On a single host XNU then binds a host route for the gateway
   address to the UPF utun, whatever interface the route names, and `ping`
   reports `No route to host`. Setting the destination to the UE address
   first makes the crossed host routes stick; `run-5gsa-oai-root.sh` does
   it. A UE on another machine needs none of this.
7. The utun the kernel assigns is named `utunN`, not `oaitun_ue1p1`. The
   patched `tuntap_if.c` logs `TUN oaitun_ue1: the kernel assigned utun7`;
   use the kernel name with `ifconfig` and `route`.
8. Threads are not pinned and not named on Darwin; `has_cap_sys_nice()`
   answers false, so every thread runs with default priority, as on Linux
   without the capability. Enough for the RF simulator.

## Layout

```
patches/                   001 to 026, git format-patch output, apply with git am
config/render.sh           copy gnb.conf and ue.conf into <OUTDIR>/oai-5gsa/
config/gnb.conf            OAI gNB: RF simulator server, band n78, 106 PRB, 30 kHz, SSB ARFCN 641280,
                           PLMN 001/01, TAC 7, AMF and NG/NGU on 127.0.0.1
config/ue.conf             OAI nrUE: the Open5GS test subscriber, DNN internet, SST 1
config/start-5gc-user.sh   mongod and the ten non-root Open5GS 5GC NFs, idempotent
config/run-5gsa-oai-root.sh  gNB restart, nrUE in tmux, p2p destination, crossed routes, ping both ways (sudo)
LICENSES/                  the upstream CSSL v1.0 text (patches and the two .conf files)
LICENSE                    MIT, the kit's own files
```

`gnb.conf` is the upstream `gnb.sa.band78.fr1.106PRB.usrpb210.conf` with
TAC 7, the AMF and NG/NGU addresses on 127.0.0.1 and `min_rxtxtime 6`. The
RF simulator block, the cell and the TDD pattern are upstream's.

## Credits and license

OpenAirInterface is developed by the OpenAirInterface Software Alliance and
the Duranta project contributors under LF Networking, and is licensed under
the Collaborative Standards Software License v1.0; its text is in
`LICENSES/CSSL-v1.0.txt`. The 26 patches are modifications to
OpenAirInterface files and are offered under those same terms, as are
`config/gnb.conf` and `config/ue.conf`, which derive from the upstream
sample configurations. The kit's own files (this README, `NOTICE`,
`config/render.sh`, `config/start-5gc-user.sh`, `config/run-5gsa-oai-root.sh`)
are under the MIT License, see `LICENSE`. `NOTICE` lists the provenance
file by file and the tools the port depends on.

Port and kit by Andrei Gosman.
