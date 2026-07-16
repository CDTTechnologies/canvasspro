import { db } from "@/lib/db";
import { NextResponse } from "next/server";

export async function GET() {
  try {
    // Get latest import headers
    const latestImport = await db.importMeta.findFirst({
      orderBy: { createdAt: "desc" },
    });
    const headers: string[] = latestImport ? JSON.parse(latestImport.headers) : [];

    // Get all households with visits
    const households = await db.household.findMany({
      include: {
        visits: { orderBy: { createdAt: "asc" } },
        _count: { select: { voters: true } },
      },
      orderBy: { createdAt: "asc" },
    });

    // Get all voters (data JSON + householdId)
    const voters = await db.voter.findMany({
      select: { id: true, data: true, householdId: true },
      orderBy: { createdAt: "asc" },
    });

    return NextResponse.json({
      headers,
      voters: voters.map((v) => ({
        id: v.id,
        data: JSON.parse(v.data),
        householdId: v.householdId,
      })),
      households: households.map((h) => ({
        id: h.id,
        householdKey: h.householdKey,
        address: h.address,
        apt: h.apt,
        fullAddress: h.fullAddress,
        city: h.city,
        state: h.state,
        zip: h.zip,
        lat: h.lat,
        lng: h.lng,
        precinct: h.precinct,
        district: h.district,
        senateDistrict: h.senateDistrict,
        commissionDistrict: h.commissionDistrict,
        schoolDistrict: h.schoolDistrict,
        subdivision: h.subdivision,
        zoning: h.zoning,
        neighborhoodCode: h.neighborhoodCode,
        landUse: h.landUse,
        propertyType: h.propertyType,
        matchType: h.matchType,
        status: h.status,
        assignedTo: h.assignedTo,
        notes: h.notes,
        tags: JSON.parse(h.tags),
        voterCount: h._count.voters,
        visits: h.visits.map((v) => ({
          id: v.id,
          date: v.date,
          time: v.time,
          outcome: v.outcome,
          statusAfter: v.statusAfter,
          notes: v.notes,
          volunteer: v.volunteer,
        })),
      })),
    });
  } catch (e) {
    console.error("GET /api/data error:", e);
    return NextResponse.json({ error: "Failed to load data" }, { status: 500 });
  }
}

export async function DELETE() {
  try {
    // Delete in order: visits (cascade), voters (cascade), households, imports
    await db.visit.deleteMany({});
    await db.voter.deleteMany({});
    await db.household.deleteMany({});
    await db.importMeta.deleteMany({});
    return NextResponse.json({ ok: true });
  } catch (e) {
    console.error("DELETE /api/data error:", e);
    return NextResponse.json({ error: "Failed to clear data" }, { status: 500 });
  }
}