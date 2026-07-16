import { db } from "@/lib/db";
import { NextRequest, NextResponse } from "next/server";

// GET /api/households/[id] — single household with voters + visits
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const hh = await db.household.findUnique({
    where: { id },
    include: {
      visits: { orderBy: { createdAt: "asc" } },
      voters: { select: { data: true } },
    },
  });
  if (!hh) return NextResponse.json({ error: "Not found" }, { status: 404 });

  return NextResponse.json({
    ...hh,
    tags: JSON.parse(hh.tags),
    voters: hh.voters.map((v) => JSON.parse(v.data)),
    visits: hh.visits.map((v) => ({
      id: v.id,
      date: v.date,
      time: v.time,
      outcome: v.outcome,
      statusAfter: v.statusAfter,
      notes: v.notes,
      volunteer: v.volunteer,
    })),
  });
}

// PATCH /api/households/[id] — update status, notes, assignedTo, tags
export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const body = await req.json();

  const data: Record<string, unknown> = {};
  if (body.status !== undefined) data.status = body.status;
  if (body.notes !== undefined) data.notes = body.notes;
  if (body.assignedTo !== undefined) data.assignedTo = body.assignedTo;
  if (body.tags !== undefined) data.tags = JSON.stringify(body.tags);

  const hh = await db.household.update({
    where: { id },
    data,
  });

  return NextResponse.json({
    ...hh,
    tags: JSON.parse(hh.tags),
  });
}