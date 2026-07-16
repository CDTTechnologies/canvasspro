import { db } from "@/lib/db";
import { NextResponse } from "next/server";

export async function GET() {
  try {
    const total = await db.household.count();
    const voters = await db.voter.count();
    const visited = await db.household.count({ where: { status: "visited" } });
    const remaining = await db.household.count({ where: { status: "not_visited" } });
    const followUp = await db.household.count({ where: { status: "follow_up" } });
    const dnr = await db.household.count({ where: { status: "do_not_return" } });

    const today = new Date().toISOString().slice(0, 10);
    const visitsToday = await db.visit.count({
      where: { date: today },
    });

    // Team stats
    const visitRecords = await db.visit.findMany({
      select: { volunteer: true },
    });
    const teamStats: Record<string, number> = {};
    for (const v of visitRecords) {
      if (v.volunteer) teamStats[v.volunteer] = (teamStats[v.volunteer] || 0) + 1;
    }

    // Precinct stats
    const households = await db.household.findMany({
      select: { precinct: true, status: true },
    });
    const precinctStats: Record<string, { total: number; visited: number }> = {};
    for (const h of households) {
      const p = h.precinct || "Unknown";
      if (!precinctStats[p]) precinctStats[p] = { total: 0, visited: 0 };
      precinctStats[p].total++;
      if (h.status === "visited") precinctStats[p].visited++;
    }

    return NextResponse.json({
      total,
      voters,
      visited,
      remaining,
      followUp,
      dnr,
      visitsToday,
      teamStats,
      precinctStats,
    });
  } catch (e) {
    console.error("GET /api/stats error:", e);
    return NextResponse.json({ error: "Failed to load stats" }, { status: 500 });
  }
}