import { db } from "@/lib/db";
import { NextRequest, NextResponse } from "next/server";

// GET /api/users — list all users
export async function GET() {
  try {
    const users = await db.appUser.findMany({
      orderBy: { createdAt: "asc" },
      select: {
        id: true,
        username: true,
        name: true,
        role: true,
        createdAt: true,
      },
    });
    return NextResponse.json(users);
  } catch (e) {
    console.error("GET /api/users error:", e);
    return NextResponse.json({ error: "Failed to load users" }, { status: 500 });
  }
}

// POST /api/users — create a new user
export async function POST(req: NextRequest) {
  try {
    const { username, password, name, role } = await req.json();
    if (!username || !password || !name || !role) {
      return NextResponse.json({ error: "All fields required" }, { status: 400 });
    }
    const existing = await db.appUser.findUnique({ where: { username } });
    if (existing) {
      return NextResponse.json({ error: "Username already exists" }, { status: 409 });
    }
    const user = await db.appUser.create({
      data: { username: username.toLowerCase(), password, name, role },
    });
    return NextResponse.json({
      id: user.id,
      username: user.username,
      name: user.name,
      role: user.role,
      createdAt: user.createdAt,
    });
  } catch (e) {
    console.error("POST /api/users error:", e);
    return NextResponse.json({ error: "Failed to create user" }, { status: 500 });
  }
}