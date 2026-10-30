//! 检查整个文件系统：`scrub`。B 树、每个数据块的校验和（重新从磁盘读）、条目之间的关系都核对一遍
//! （scrub 系统调用），打印统计；坏了打印错误，退出码 1。

const sys = @import("sys");

pub fn main() u8 {
    const st = sys.scrub() catch |err| {
        sys.print("scrub: the file system is damaged: {s}\n", .{@errorName(err)});
        return 1;
    };
    sys.print("scrub: ok: {d} files, {d} dirs, {d} data blocks verified\n", .{ st.files, st.dirs, st.data_blocks });
    sys.print("scrub: tree of {d} nodes, {d} items, height {d}; {d} of {d} blocks free, generation {d}\n", .{
        st.nodes, st.items, st.height, st.free_blocks, st.blocks, st.generation,
    });
    return 0;
}
