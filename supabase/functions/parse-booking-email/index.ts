import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

/** OpenAI-compatible nullable helpers (prefer `anyOf` over `type: [x, null]`). */
const NULLABLE_STRING = { anyOf: [{ type: "string" }, { type: "null" }] };
const NULLABLE_INT = { anyOf: [{ type: "integer" }, { type: "null" }] };

/** JSON Schema for structured output — matches `places.booking_details` / Swift `BookingDetailUnion` (camelCase keys). */
const BOOKING_PARSE_SCHEMA = {
  name: "booking_email_parse",
  strict: true,
  schema: {
    oneOf: [
      {
        type: "object",
        properties: {
          type: { type: "string", enum: ["flight"] },
          airline: { type: "string" },
          flightNumber: { type: "string" },
          departureAirport: { type: "string" },
          arrivalAirport: { type: "string" },
          departureTime: {
            ...NULLABLE_STRING,
            description: "ISO 8601 datetime or null",
          },
          arrivalTime: {
            ...NULLABLE_STRING,
            description: "ISO 8601 datetime or null",
          },
          terminal: { type: "string" },
          gate: { type: "string" },
          seat: { type: "string" },
        },
        required: [
          "type",
          "airline",
          "flightNumber",
          "departureAirport",
          "arrivalAirport",
          "departureTime",
          "arrivalTime",
          "terminal",
          "gate",
          "seat",
        ],
        additionalProperties: false,
      },
      {
        type: "object",
        properties: {
          type: { type: "string", enum: ["hotel"] },
          checkInDate: NULLABLE_STRING,
          checkInTime: NULLABLE_STRING,
          checkOutDate: NULLABLE_STRING,
          checkOutTime: NULLABLE_STRING,
          roomType: { type: "string" },
          nights: NULLABLE_INT,
        },
        required: [
          "type",
          "checkInDate",
          "checkInTime",
          "checkOutDate",
          "checkOutTime",
          "roomType",
          "nights",
        ],
        additionalProperties: false,
      },
      {
        type: "object",
        properties: {
          type: { type: "string", enum: ["restaurant"] },
          reservationTime: NULLABLE_STRING,
          partySize: NULLABLE_INT,
        },
        required: ["type", "reservationTime", "partySize"],
        additionalProperties: false,
      },
      {
        type: "object",
        properties: {
          type: { type: "string", enum: ["car_rental"] },
          company: { type: "string" },
          pickupLocation: { type: "string" },
          dropoffLocation: { type: "string" },
          pickupTime: NULLABLE_STRING,
          dropoffTime: NULLABLE_STRING,
          carType: { type: "string" },
        },
        required: [
          "type",
          "company",
          "pickupLocation",
          "dropoffLocation",
          "pickupTime",
          "dropoffTime",
          "carType",
        ],
        additionalProperties: false,
      },
      {
        type: "object",
        properties: {
          type: { type: "string", enum: ["activity"] },
          provider: { type: "string" },
          duration: NULLABLE_STRING,
          ticketNumber: { type: "string" },
        },
        required: ["type", "provider", "duration", "ticketNumber"],
        additionalProperties: false,
      },
      {
        type: "object",
        properties: {
          type: { type: "string", enum: ["transport"] },
          operatorName: { type: "string" },
          serviceNumber: { type: "string" },
          departureStation: { type: "string" },
          arrivalStation: { type: "string" },
          departureTime: NULLABLE_STRING,
          arrivalTime: NULLABLE_STRING,
          seat: { type: "string" },
        },
        required: [
          "type",
          "operatorName",
          "serviceNumber",
          "departureStation",
          "arrivalStation",
          "departureTime",
          "arrivalTime",
          "seat",
        ],
        additionalProperties: false,
      },
    ],
  },
};

function getFormField(form: FormData, ...keys: string[]): string | null {
  for (const key of keys) {
    const v = form.get(key);
    if (typeof v === "string" && v.length > 0) return v;
  }
  return null;
}

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function parseBookingWithOpenAI(
  apiKey: string,
  emailBody: string,
  subject: string,
): Promise<Record<string, unknown>> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      temperature: 0.1,
      response_format: {
        type: "json_schema",
        json_schema: BOOKING_PARSE_SCHEMA,
      },
      messages: [
        {
          role: "system",
          content:
            `You extract structured travel booking data from forwarded confirmation emails for the Wayfind app. ` +
            `Choose exactly one booking \`type\`: flight, hotel, restaurant, car_rental, activity, or transport. ` +
            `Use camelCase field names as in the schema. ` +
            `For unknown string fields use an empty string. Use null for unknown dates, times, or numeric optionals. ` +
            `Dates/times should be ISO 8601 strings when you can infer them; otherwise null. ` +
            `The email body may include quoted threads; prefer the most recent confirmation details.`,
        },
        {
          role: "user",
          content: `Subject: ${subject}\n\nEmail body:\n${emailBody}`,
        },
      ],
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`OpenAI HTTP ${res.status}: ${errText}`);
  }

  const completion = (await res.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const raw = completion.choices?.[0]?.message?.content;
  if (!raw) throw new Error("OpenAI returned no message content");

  const parsed = JSON.parse(raw) as Record<string, unknown>;
  return parsed;
}

async function invokeSendPush(
  supabaseUrl: string,
  serviceRoleKey: string,
  payload: { user_id: string; title: string; body: string; data?: unknown },
): Promise<void> {
  const res = await fetch(`${supabaseUrl}/functions/v1/send-push`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const t = await res.text();
    console.error("send-push invoke failed:", res.status, t);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  }

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!openaiKey || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, { ok: false, error: "missing_server_config" });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_multipart" });
  }

  const recipient = getFormField(form, "recipient", "Recipient")?.trim() ?? "";
  const sender = getFormField(form, "sender", "Sender") ?? "";
  const subject = getFormField(form, "subject", "Subject") ?? "";
  const bodyText =
    getFormField(form, "stripped-text", "stripped_text", "Stripped-text") ??
    getFormField(form, "body-plain", "body_plain", "Body-plain") ??
    "";

  if (!recipient) {
    return jsonResponse(200, { ok: false, error: "missing_recipient" });
  }

  const emailBody = bodyText.trim() || "(empty body)";

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("id")
    .ilike("forwarding_email", recipient)
    .maybeSingle();

  if (profileError) {
    console.error("profiles lookup:", profileError);
    return jsonResponse(500, { ok: false, error: "profile_lookup_failed" });
  }
  if (!profile) {
    return jsonResponse(200, {
      ok: false,
      error: "unknown_forwarding_address",
    });
  }

  const userId = profile.id as string;

  const { data: trip, error: tripError } = await supabase
    .from("trips")
    .select("id")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (tripError) {
    console.error("trips lookup:", tripError);
    return jsonResponse(500, { ok: false, error: "trip_lookup_failed" });
  }
  if (!trip) {
    return jsonResponse(200, { ok: false, error: "no_trips_for_user" });
  }

  const tripId = trip.id as string;

  const { data: inserted, error: insertError } = await supabase
    .from("parsed_bookings")
    .insert({
      user_id: userId,
      trip_id: tripId,
      status: "pending",
      raw_email_body: emailBody,
    })
    .select("id")
    .single();

  if (insertError || !inserted) {
    console.error("parsed_bookings insert:", insertError);
    return jsonResponse(500, { ok: false, error: "insert_failed" });
  }

  const bookingId = inserted.id as string;

  let parsedData: Record<string, unknown>;
  try {
    parsedData = await parseBookingWithOpenAI(openaiKey, emailBody, subject);
  } catch (e) {
    console.error("OpenAI parse failed:", e);
    await supabase
      .from("parsed_bookings")
      .update({ status: "failed" })
      .eq("id", bookingId);
    return jsonResponse(200, {
      ok: false,
      error: "openai_failed",
      booking_id: bookingId,
    });
  }

  const { error: updateError } = await supabase
    .from("parsed_bookings")
    .update({
      status: "parsed",
      parsed_data: parsedData,
    })
    .eq("id", bookingId);

  if (updateError) {
    console.error("parsed_bookings update:", updateError);
    return jsonResponse(500, {
      ok: false,
      error: "update_failed",
      booking_id: bookingId,
    });
  }

  await invokeSendPush(supabaseUrl, serviceRoleKey, {
    user_id: userId,
    title: "Booking ready to review",
    body: "We parsed a new confirmation from your email.",
    data: {
      kind: "parsed_booking",
      parsed_booking_id: bookingId,
      trip_id: tripId,
      sender,
      subject,
    },
  });

  return jsonResponse(200, {
    ok: true,
    booking_id: bookingId,
    trip_id: tripId,
  });
});
