import { db } from "@/lib/db";
import { NextRequest, NextResponse } from "next/server";

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const body = await req.json();
  const { date, time, outcome, statusAfter, notes, volunteer } = body;

  if (!date) {
    return NextResponse.json({ error: "Date is required" }, { status: 400 });
  }

  // Create the visit
  const visit = await db.visit.create({
    data: {
      householdId: id,
      date,
      time: time || "",
      outcome: outcome || "",
      statusAfter: statusAfter || "not_visited",
      notes: notes || "",
      volunteer: volunteer || "",
    },
  });

  // Update household status if provided
  if (statusAfter) {
    await db.household.update({
      where: { id },
      data: { status: statusAfter },
    });
  }

  return NextResponse.json({
    id: visit.id,
    date: visit.date,
    time: visit.time,
    outcome: visit.outcome,
    statusAfter: visit.statusAfter,
    notes: visit.notes,
    volunteer: visit.volunteer,
  });
}