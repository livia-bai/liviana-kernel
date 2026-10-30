# 文件系统

涉及文件：`src/fs.zig`（文件系统本身）、`src/fsys.zig`（接进内核）、`src/mkfs.zig`（主机上生成磁盘镜像）；调用方：`src/syscall.zig`、`src/file.zig`；建在写时复制 B 树上（`src/ctree.zig`、`src/btree.zig`，[btree.md](btree.md)），数据块的读写走缓冲区缓存（[disk.md](disk.md#缓冲区缓存biozig)）

文件系统的所有东西——inode、目录、文件内容——都是写时复制 B 树里的条目，照 btrfs 的条目设计简化。`fs.zig` 只有文件系统本身的逻辑：不加锁、不知道进程、不直接碰用户内存（读写通过调用方给的 `out`、`in`）。内核、主机上的 `mkfs`、单元测试都用它。

## 条目

键是 `(objectid, type, offset)`，`objectid` 都是 inode 号，所以一个文件的所有条目在树里挨在一起：

| 键 | 数据 | 说明 |
| --- | --- | --- |
| `(ino, 1, 0)` | `Inode { kind, size, parent }`（24 字节） | 种类（文件、目录）、长度、所在的目录 |
| `(目录 ino, 2, 散列 << 32 \| 序号)` | `DirHeader { ino, kind, name_len }` + 名字 | 目录项。散列是名字的 crc32c |
| `(ino, 3, 页号 × 4096)` | `ExtentHeader { kind, csum }` + 内容或 `{ blockno, generation }` | 文件第几页的内容：内联，或者指向一个数据块 |

- 根目录的 inode 号是 1。新 inode 号是树里最大的 `objectid` + 1：挂载时用 `Volume.lastKey()` 算出来，之后递增，不重用。
- 没有硬链接，一个 inode 只有一个名字；也没有 Unix 的 inode 引用计数。
- 所有结构体都是 `extern struct`，内核和主机上看到的布局一样。

## 目录

**目录项按名字的散列排序**：键的 `offset` 是 `散列 << 32 | 序号`。查一个名字时从 `(dir, 2, 散列 << 32)` 开始往后看所有散列相同的目录项（`Volume.next`），逐个比名字。插入时序号用这些目录项里最大的序号 + 1，所以散列相同的名字也分得开（单元测试用了一对事先找好的 crc32c 相同的名字 `n1371838`、`n2000402`）。btrfs 的 `DIR_ITEM` 也是按名字的散列做键，散列冲突时把几个名字放进同一个条目。

**目录里不存 "." 和 ".."**：路径里遇到 `.` 就是自己，遇到 `..` 用 `Inode.parent`（根目录的 `parent` 是它自己）。

**`readdir(dir, cookie, name)`** 返回键 `>= (dir, 2, cookie)` 的第一个目录项和下一次用的 `cookie`（这一项的 `offset + 1`），从 0 开始，没有了返回 null。顺序就是散列的顺序。cookie 是键，不是下标，所以列目录的过程中别的名字被删了、加了，也不会重复或者跳过还在的名字。

**路径**（`resolve`）：以 `/` 开头的从根目录找，否则从调用方给的当前目录找；多个 `/` 当一个；中间的每一段都必须是目录（`NotDir`）。名字最长 255 字节（`NameTooLong`）；创建、删除时最后一段不能是空的、`.`、`..`（`InvalidName`）。

**删除**（`unlink`）：目录必须是空的（`NotEmpty`）；删掉这个 inode 号的所有条目（inode 和文件内容，指向的数据块一起释放），再删目录项。还打开着它的文件、以它为当前目录的进程之后再用它，会得到 `NotFound`：没有 Unix 那种“最后一个打开的人关掉才真正删除”。

## 文件内容

文件按 4 KiB 一页存，一页一个条目：

- **内联**：整个文件不超过 `inline_max`（512）字节时，内容直接放在第 0 页的条目里，不占数据块（btrfs 的 inline extent）。内联条目的数据长度就是文件长度。写的时候整个条目读出来、改、写回去（`writeInline`）。
- **数据块**：文件长到 512 字节以上时，先把内联的内容搬进一个数据块（`unInline`），之后每页一个数据块。条目里记着块号、写它的事务号和内容的 crc32c。
- **洞**：没有条目的页读出来是 0，不占块。往文件末尾之后很远的地方写，中间就是洞。
- **长度之外的字节总是 0**：新分配的页先清零（不是整页覆盖的话），内联转数据块时剩下的部分清零。所以文件变长时不用专门去清零。

**写**（`write`）：对每一页，分配一个**新**数据块；不是整页覆盖的话先把旧内容复制过来（没有旧的就清零）；再从 `in` 取新内容；算校验和、写下去；条目改成指向新块，旧块交给 `Volume.freeData`。数据块和树的节点一样写时复制：已提交的树指向的数据块从来不改，属于已提交的树的旧块要等提交之后才能再分配（[btree.md](btree.md#事务和提交)）。最后改 inode 的长度。

**读**（`read`）：对每一页查条目：洞给 0，内联的从条目里取，数据块的读出来交给 `out`。数据块从磁盘读进来时（`bio.load` 返回 true）核对条目里记的 crc32c，对不上是 `Corrupt`：btrfs 也对数据做校验和，只是存在单独的一棵树里。

**截断**（`truncate`）：现在只能截成 0（`open` 时的 `O_TRUNC`），删掉所有内容条目、释放数据块，长度设成 0。之后再写又从内联开始。

**挂载时**，`ctree` 走树算用着的块，也要算上数据块：`fs.mount` 先把 `Volume.data_refs` 设成 `dataRefs`，它对指向数据块的内容条目返回那个块，`walk` 把它记成用着的（同一块被引用两次是 `Corrupt`）。挂载只读树的节点，不读数据块。

**读写的对象**：`read(ino, off, len, out)` 把内容交给 `out.put(在这次读里的位置, 字节)`，`write(ino, off, len, in)` 从 `in.get(在这次写里的位置, 目标)` 取内容。内核里它们是用户内存（`vm.copyToUser`、`copyFromUser`，可能返回 `BadAddress`），单元测试里是一个切片。数据块的内容从缓冲区直接复制到用户内存，不经过内核栈上的临时缓冲区（内联的内容不超过 512 字节，经过栈上的一个小缓冲区）。

## 事务：每个操作提交一次

```zig
pub fn run(fs: *Fs, comptime op: anytype, args: anytype) Error!...
```

调用方用 `fs.run(Fs.write, .{ ino, off, len, in })` 这样的方式做每一个操作：操作成功就 `Volume.commit()`，出错就 `Volume.abort()`。一个操作（比如创建文件 = 插入 inode + 插入目录项，或者写 10 页）在 ctree 里是好几次修改，中间任何一步出错（磁盘满、读到坏块、用户内存不对），之前做了的一起作废。所以**每个操作要么全做了、要么什么都没做**，掉电也一样：掉电时最后一个操作要么提交了，要么没有。

代价是每个操作都写一次超级块。以后可以把几个操作攒在一个事务里（xv6 的日志也是攒着一起提交）。

## 接进内核（`fsys.zig`）

```zig
var vol: ctree.Volume = .{};   // 唯一的一个卷
var root: fs.Fs = undefined;   // 挂载好的文件系统
pub var mounted = false;
pub var lock: Sleeplock = .init("fs");
pub var raw_base: u64 = 0;     // 原始区域：文件系统之后的块
pub var raw_count: u64 = 0;

pub fn init() void                    // 挂载
pub fn get() error{NoDevice}!*Fs      // 拿着 lock 返回文件系统
pub fn unlock() void
pub fn errno(err: anyerror) abi.Errno // 文件系统的错误 → 系统调用的错误码
```

**挂载**：第一个进程（init）第一次回到 U 模式之前，在 `forkretC` 里调用 `fsys.init()`（xv6 的 `forkret` 里调用 `fsinit` 也是这个原因）：挂载要读盘，读盘要睡着等中断，只有进程能做，`kmain` 不行。之后创建的进程都在这之后运行。成功时打印

```
[ok] file system: 6840 of 7168 blocks free, generation 27
```

磁盘上没有文件系统时打印 `[warn] no file system on the disk: NotFormatted`（接一块全 0 的 4 MiB 镜像实测；超级块坏了是别的错误名），照常启动：文件系统的系统调用返回 `-ENODEV`（`ls /` 打印 `ls: /: NoDevice`），整个磁盘都是原始区域。

**一把睡眠锁管整个文件系统**：每个系统调用拿着 `fsys.lock` 做完整个操作（包括读写文件时在缓冲区和用户内存之间复制），所以 `fs.zig`、`ctree.zig` 里不用加锁，同一时刻只有一个进程在用文件系统。代价是两个进程读写不同的文件也要排队；xv6 的 inode 各有一把睡眠锁，可以并行，这里的 B 树是整棵写时复制的，一个事务改的是整条路径，按文件分锁不容易。

- 是睡眠锁：拿着它要读写磁盘（睡着等）。拿它之前不能拿着自旋锁；它在缓冲区的睡眠锁之前拿（`fsys.lock` → 缓冲区的睡眠锁 → `virtio_disk.lock`），回到 U 模式之前放开。
- `File.off`（几个 fd 共用的读写位置）也由它保护：读写的整个过程拿着它，并发的 `write` 不会写到同一个位置上。
- 原始区域只由 `readblock`、`writeblock` 读写，不拿 `fsys.lock`：它和文件系统用的块不重叠。

**打开的文件**：`file.File` 多了一种 `.inode`，记着 inode 号 `ino` 和读写位置 `off`（[files.md](files.md)）。`read`、`write` 系统调用对它调用 `fs.read`、`fs.run(Fs.write, ...)`，`out`、`in` 是 `UserOut`、`UserIn`（用户地址空间和指针，经 `vm.copyToUser`、`copyFromUser`，[syscalls.md](syscalls.md#访问用户内存)），成功了才挪 `off`。

**每个进程有当前目录**：`Process.cwd`（inode 号，从根目录开始），`fork` 继承，`exec` 不变，只有自己读写（`chdir`）。相对路径从它开始找。

**系统调用**（[syscalls.md](syscalls.md#调用列表)）：

| 调用 | 做什么 |
| --- | --- |
| `open(path, flags)` | `resolve`；没有并且带 `O_CREATE` 时 `create`；是目录并且要写是 `EISDIR`；带 `O_TRUNC` 并且可写时 `truncate`。返回 fd |
| `mkdir(path)`、`unlink(path)` | `create(.dir)`、`unlink` |
| `chdir(path)` | `resolve`，不是目录是 `ENOTDIR` |
| `fstat(fd)` | inode 号、长度、种类；串口和管道也能查（种类是 `console`、`pipe`） |
| `readdir(fd)` | 目录的下一项：`File.off` 就是 `fs.readdir` 的 cookie，结果写进用户内存成功了才往后挪 |
| `read`、`write` | 从 `off` 开始读写；读写目录是 `EISDIR` |
| `scrub` | 先作废缓存，再 `check` 整个文件系统（[检查](#检查整个文件系统checkscrub)） |
| `exec` | 在 `/bin`（或给的路径）里找程序，拿着 `fsys.lock` 把 ELF 直接读进新的用户页（[process.md](process.md#程序从哪来)） |

路径先复制进内核栈上的缓冲区（最长 `abi.max_path` = 256 字节，长了是 `ENAMETOOLONG`）。错误码：`NotFound` → `ENOENT`，`Exists` → `EEXIST`，`NotDir` → `ENOTDIR`，`IsDir` → `EISDIR`，`NotEmpty` → `ENOTEMPTY`，`NameTooLong` → `ENAMETOOLONG`，`InvalidName` → `EINVAL`，`NoSpace` → `ENOSPC`，`FileTooBig` → `EFBIG`，`BadAddress` → `EFAULT`，`Corrupt` 等磁盘上的东西不对 → `EIO`。

**内核栈**：系统调用在 16 KiB 的进程内核栈上运行，B 树的操作走得很深。开发时内核栈被撑爆过一次（Debug 模式用到 54 KiB）：`std.bit_set` 的 `isSet`、`count` 按值接收整个位图，每调用一次在栈上复制 8 KiB；`x.* = y.*` 复制 4 KiB 的块也会先放在栈上。改成自己写的 `Bitmap`（方法接收指针）和 `@memcpy` 之后，实测跑完全部 QEMU 测试（包括 `t_fs`、掉电后重新启动、从文件系统 `exec`），最深 Debug 9944 字节、safe 5840 字节、small 5096 字节（测法见 [process.md](process.md#进程表)）。

## 检查整个文件系统（`check`、`scrub`）

`Fs.check` 把整个文件系统核对一遍，只读不改，哪里不对就是 `Corrupt`。单元测试几乎每一步之后都调用它（包括掉电测试的每一次重新挂载），`mkfs` 写完镜像调用一次，运行中由 `scrub` 系统调用调用（用户程序 `scrub`，[user-programs.md](user-programs.md#scrub)）。核对的东西：

- **B 树**：`Volume.check`，每个节点的校验和、块号、事务号、层数，键的顺序和上下界，空闲空间的位图正好是没被树（和等着释放的）用着的块（[btree.md](btree.md#检查check)）。
- **每个数据块**：按内容条目读一遍（`readData`），核对条目里记的 crc32c。
- **条目之间**：按键的顺序扫一遍所有条目（同一个 inode 的条目挨在一起，inode 条目在最前面），一边扫一边核对：
  - 每个条目前面都有它的 inode 条目，inode 号小于 `next_ino`；inode 的种类是文件或目录。
  - 目录项只出现在目录里：名字合法（`checkName`）、长度和头里的 `name_len` 一样、键里的散列就是名字的散列；指向的 inode 存在、种类和目录项里记的一样、`parent` 就是这个目录；不能指向根目录。
  - 内容条目只出现在文件里，偏移是 4096 的倍数、在文件长度之内；内联的只能是第 0 页、长度正好是文件长度（不超过 512），后面不能再有别的内容条目。
  - 根目录是目录、`parent` 是自己；别的目录沿着 `parent` 往上走得到根目录（走的步数超过 inode 号的个数就是有环，比如两个目录互为 `parent`、和根目录断开了）。
  - 除了根目录，每个 inode 正好有一个目录项指着它（没有硬链接）。不用记下每个 inode 号：目录项指向的 inode 号和 inode 条目的 inode 号各算一份“指纹”——个数、和、每个号搅乱（splitmix64）之后的和，都是回绕的加法，和顺序无关——三样都一样才算对上。一个 inode 两个名字、另一个没有名字，这三样同时对上的概率可以忽略。

返回文件数、目录数、核对过的数据块数，以及 B 树的节点数、条目数、层数。

**缓存**：校验和只在从磁盘读进来的时候核对（`bio.load` 返回 true 时），缓存里的块不再算。`scrub` 要核对的是磁盘上的内容，所以先 `bio.invalidate()`，把没人在用的缓冲区都作废（[disk.md](disk.md#写和放开)），之后读到的每一块都是刚从磁盘读的。

**`scrub` 系统调用**（30 号）：拿着 `fsys.lock` 做完，期间别的进程的文件操作都在等，缓存里也不会有做到一半的操作（每个操作在放开锁之前都写完了）。都对的话把 `abi.ScrubInfo`（上面这些数，加上空闲块数、总块数、事务号）写进用户内存；`Corrupt` 返回 `-EIO`。实测刚启动、跑完 `t_fs` 之后：

```
> run scrub
scrub: ok: 33 files, 2 dirs, 197 data blocks verified
scrub: tree of 8 nodes, 267 items, height 2; 6961 of 7168 blocks free, generation 723
[proc] pid 4 (scrub) exited with code 0
```

QEMU 测试里在镜像上改坏 `/scrub.dat` 一个数据块的一个字节，再启动：

```
> run scrub
scrub: the file system is damaged: IoError
[proc] pid 3 (scrub) exited with code 1
```

`cat` 这个文件先输出没坏的第 0 页，读到第 1 页时报 `cat: /scrub.dat: IoError`；`rm` 它不读数据块，能删掉，删掉之后 `scrub` 又通过了。

只能发现问题，不能修：坏了的数据块没有副本可以换（btrfs 的 scrub 用镜像副本修复）。

## 生成磁盘镜像（`mkfs.zig`）

```
mkfs <输出文件> <总块数> <文件系统的块数> <文件>...
```

主机上的程序，`build.zig` 构建时运行它（xv6 的 `mkfs/mkfs.c`）：用 `fs.zig`、`ctree.zig`、`bio.zig` 这几个和内核同一份的文件，磁盘是内存里的一块数组（`bio` 的 `Device`）。`Fs.format` 格式化前 7168 块，建 `/bin`，把选中的每个用户程序的 ELF 装成 `/bin/<名字>`，跑一遍 `check`，再给后面 1024 块的原始区域填上固定图案（[disk.md](disk.md#qemu-的磁盘)），写出镜像文件。`mkfs.zig` 是一个单独的主机程序的根，和内核、单元测试是不同的编译，所以可以和它们共用 `src/` 下的文件（一个文件在一次编译里只能属于一个模块）。

## 单元测试

都在主机上，用内存当磁盘：

- 目录：创建、`resolve`（`.`、`..`、多余的 `/`、相对路径）；`Exists`、`NotFound`、`NotDir`、`InvalidName`、`NameTooLong`、`IsDir`；最长的名字（255 字节）找得到、列得出来、删得掉；删除非空目录是 `NotEmpty`；删了之后找不到，inode 号不重用。
- `readdir` 列出 62 个名字一个不少、不重复；散列相同的两个名字都找得到，删掉一个另一个还在。
- 文件内容：内联的读写、中间补 0；正好 512 字节还是内联，再长一个字节换成数据块、内容不变；跨页的写；洞读出来是 0、不占块；读到末尾之后返回 0；写到一半“用户内存”出错，整个写作废、文件不变；`FileTooBig`；截断之后再写又是内联；删除文件之后空闲块数和创建之前一样。
- 数据块的校验和：在磁盘上改一个字节，读这一页是 `Corrupt`，别的页照常；重新挂载之后内容还在。
- `check`：数对文件、目录（含根目录）、数据块（有洞的文件只算有块的页）；在磁盘上改一个数据块、改根节点，缓存里还是好的时 `check` 照样通过，`bio.invalidate` 之后就是 `Corrupt`，改回来又通过。条目之间对不上的 8 种坏法（没有名字的 inode、指向不存在的 inode 的目录项、`parent` 不对、没有 inode 的条目、内容条目超出文件长度、一个 inode 两个名字、两个目录成环、文件里有目录项）在当前事务里直接改 B 树做出来，每一种都是 `Corrupt`，`abort` 之后又通过。验证过它能抓住错误：去掉“每个 inode 正好一个名字”那一项，没有名字的 inode 就查不出来了。
- **掉电**：一串 25 个随机操作（创建、删除、截断、在随机位置写最多 3 页），每个操作提交一次，完整跑一遍写盘 120 次；对每一个 N，在第 N 次写之后掉电，重新挂载，要求：挂载成功、`check` 通过、所有文件的内容正好是某一个操作做完之后的样子、不早于最后一个做完了的操作。然后接着创建、写一个新文件，再核对一遍旧文件：挂载时漏算了哪个块（当成了空闲块），这里就会被改写。

  验证过它能抓住错误：改数据页时直接在旧块上改（不写时复制），掉电测试失败；挂载时不把数据块算作用着的（`dataRefs` 总返回 null），掉电测试失败（这一种是在加了“挂载之后接着写”之后才抓到的）。

## QEMU 里的测试

`tools/qemu_test.py` 的 `fs` 用例（[testing.md](testing.md)）：shell 里的 `ls`、`cat`、`mkdir`、`rm`、`cd`、`<`、`>`；回归测试 `t_fs` 测系统调用的边界情况和并发；关机之后在同一个镜像上再启动，上一次写的文件还在；然后边写边把 QEMU 杀掉（掉电），再启动一次，`t_fs verify` 检查每个操作要么做完了、要么没做，`scrub` 通过；最后在镜像里改坏一个数据块，第四次启动，`scrub` 发现它（见上面的[检查](#检查整个文件系统checkscrub)）。

这个用例在开发时抓到过一个 bug：目录项的头里名字长度是 `u8`，`@sizeOf(DirHeader) + head.name_len` 按 `u8` 算，名字长于 239 字节时溢出（Debug、safe 模式下 panic；fast、small 模式下不检查溢出，是未定义行为）。单元测试原来只建了 255 字节的名字，没有再找它、列它，碰不到这段代码，现在补上了。

## 限制和以后可以做的

- 只能截成 0；没有 `rename`、硬链接、权限、时间戳。
- 一页一个数据块，没有 btrfs 那种连续多块的 extent；也没有压缩。
- 每个操作一个事务，每次都写超级块。
- 删除打开着的文件之后，打开它的人再读写会出错（`ENOENT`）。
- 一把锁管整个文件系统，读写不同文件的进程也要排队。
- 没有 `lseek`：读写位置只能从 0 开始往后挪。
