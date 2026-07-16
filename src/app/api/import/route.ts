import { db } from "@/lib/db";
import { NextRequest, NextResponse } from "next/server";

function makeHouseholdKey(v: Record<string, string>): string {
  const a = (v.Address || "").trim().toUpperCase().replace(/\s+/g, " ");
  const u = (v.AptorBoxNumber || "").trim().toUpperCase().replace(/\s+/g, " ");
  const z = (v.ZipCode || "").trim();
  return `${a}|${u}|${z}`;
}

export async function POST(req: NextRequest) {
  try {
    const { headers, voters: voterRows } = await req.json();

    if (!headers || !voterRows || !voterRows.length) {
      return NextResponse.json({ error: "No data provided" }, { status: 400 });
    }

    // Clear old data
    await db.visit.deleteMany({});
    await db.voter.deleteMany({});
    await db.household.deleteMany({});
    await db.importMeta.deleteMany({});

    // Group by household key
    const householdMap = new Map<
      string,
      {
        key: string;
        voter: Record<string, string>;
        voterRows: Record<string, string>[];
      }
    >();

    for (const v of voterRows) {
      const key = makeHouseholdKey(v);
      if (!householdMap.has(key)) {
        householdMap.set(key, { key, voter: v, voterRows: [] });
      }
      householdMap.get(key)!.voterRows.push(v);
    }

    // Create households
    const householdIdMap = new Map<string, string>(); // key -> db id

    for (const [, group] of householdMap) {
      const v = group.voter;
      const lat = parseFloat(v.Latitude);
      const lng = parseFloat(v.Longitude);

      const hh = await db.household.create({
        data: {
          householdKey: group.key,
          address: (v.Address || "").trim(),
          apt: (v.AptorBoxNumber || "").trim(),
          fullAddress: [v.Address, v.AptorBoxNumber, v.City, v.State, v.ZipCode]
            .filter((x) => x && x.trim())
            .join(" ")
            .trim(),
          city: (v.City || "").trim(),
          state: (v.State || "").trim(),
          zip: (v.ZipCode || "").trim(),
          lat: isNaN(lat) ? null : lat,
          lng: isNaN(lng) ? null : lng,
          precinct: (v.PrecinctName || "").trim(),
          district: (v.StateHouseDistrict || "").trim(),
          senateDistrict: (v.StateSenateDistrict || "").trim(),
          commissionDistrict: (v.CountyCommissionDistrict || "").trim(),
          schoolDistrict: (v.SchoolDistrict || "").trim(),
          subdivision: (v.Prop_SubdivisionName || "").trim(),
          zoning: (v.Prop_ZoningDescription || "").trim(),
          neighborhoodCode: (v.Prop_NeighborhoodCode || "").trim(),
          landUse: (v.Prop_LandUseType || "").trim(),
          propertyType: (v.Prop_PropertyType || "").trim(),
          matchType: (v.Prop_MatchType || "").trim(),
          voterCount: group.voterRows.length,
        },
      });
      householdIdMap.set(group.key, hh.id);
    }

    // Create voters
    for (const v of voterRows) {
      const key = makeHouseholdKey(v);
      const householdId = householdIdMap.get(key);
      if (!householdId) continue;

      await db.voter.create({
        data: {
          data: JSON.stringify(v),
          householdId,
          lastName: (v.LastName || "").trim(),
          firstName: (v.FirstName || "").trim(),
          address: (v.Address || "").trim(),
          city: (v.City || "").trim(),
          state: (v.State || "").trim(),
          zipCode: (v.ZipCode || "").trim(),
          party: (v.PartyLastPrimary || "").trim(),
          phone: (v.Phone || "").trim(),
          email: (v.Email || "").trim(),
        },
      });
    }

    // Save import metadata
    await db.importMeta.create({
      data: {
        fileName: "import",
        headers: JSON.stringify(headers),
        voterCount: voterRows.length,
        householdCount: householdMap.size,
      },
    });

    return NextResponse.json({
      ok: true,
      voterCount: voterRows.length,
      householdCount: householdMap.size,
    });
  } catch (e) {
    console.error("POST /api/import error:", e);
    return NextResponse.json({ error: "Import failed" }, { status: 500 });
  }
}