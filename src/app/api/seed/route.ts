import { db } from "@/lib/db";
import { NextResponse } from "next/server";

export async function GET() {
  // Seed demo users if none exist
  const count = await db.appUser.count();
  if (count === 0) {
    await db.appUser.createMany({
      data: [
        { username: "admin", password: "admin123", name: "Campaign Admin", role: "admin" },
        { username: "staff", password: "staff123", name: "Sarah Mitchell", role: "staff" },
        { username: "volunteer", password: "vol123", name: "Jake Torres", role: "volunteer" },
      ],
    });
  }
  return NextResponse.json({ seeded: true });
}