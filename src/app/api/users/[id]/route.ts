import { db } from "@/lib/db";
import { NextRequest, NextResponse } from "next/server";

// PATCH /api/users/[id] — update a user
export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  try {
    const body = await req.json();
    const data: Record<string, unknown> = {};
    if (body.name !== undefined) data.name = body.name;
    if (body.role !== undefined) data.role = body.role;
    if (body.password !== undefined && body.password !== "") data.password = body.password;

    const user = await db.appUser.update({ where: { id }, data });
    return NextResponse.json({
      id: user.id,
      username: user.username,
      name: user.name,
      role: user.role,
      createdAt: user.createdAt,
    });
  } catch (e) {
    console.error("PATCH /api/users/[id] error:", e);
    return NextResponse.json({ error: "Failed to update user" }, { status: 500 });
  }
}

// DELETE /api/users/[id] — delete a user
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  try {
    // Don't allow deleting the last admin
    const user = await db.appUser.findUnique({ where: { id } });
    if (!user) {
      return NextResponse.json({ error: "User not found" }, { status: 404 });
    }
    if (user.role === "admin") {
      const adminCount = await db.appUser.count({ where: { role: "admin" } });
      if (adminCount <= 1) {
        return NextResponse.json(
          { error: "Cannot delete the last admin" },
          { status: 400 }
        );
      }
    }
    await db.appUser.delete({ where: { id } });
    return NextResponse.json({ ok: true });
  } catch (e) {
    console.error("DELETE /api/users/[id] error:", e);
    return NextResponse.json({ error: "Failed to delete user" }, { status: 500 });
  }
}