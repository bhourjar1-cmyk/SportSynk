-- ============================================================
-- SportSynk Booking System
-- ============================================================

-- 1. Prevent duplicate slots
ALTER TABLE public.slots
ADD CONSTRAINT unique_slot_time
UNIQUE (date, start_time, end_time, court_number);


-- 2. Create slots automatically for a selected date
CREATE OR REPLACE FUNCTION public.ensure_slots_for_date(
    p_date DATE
)
RETURNS SETOF public.slots
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN

    INSERT INTO public.slots
        (date, start_time, end_time, court_number, is_available)
    VALUES
        (p_date, '10:00', '11:00', 1, true),
        (p_date, '11:00', '12:00', 1, true),
        (p_date, '12:00', '13:00', 1, true),
        (p_date, '13:00', '14:00', 1, true)

    ON CONFLICT (date, start_time, end_time, court_number)
    DO NOTHING;

    RETURN QUERY
    SELECT *
    FROM public.slots
    WHERE date = p_date
    ORDER BY start_time, court_number;

END;
$$;


-- 3. Allow logged-in users to execute the function
GRANT EXECUTE
ON FUNCTION public.ensure_slots_for_date(DATE)
TO authenticated;


-- 4. Create a booking request safely
CREATE OR REPLACE FUNCTION public.create_booking_request(
    p_slot_id UUID
)
RETURNS public.bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_booking public.bookings;
    v_slot public.slots;
BEGIN

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User is not authenticated';
    END IF;


    -- Lock the slot so two users cannot book it simultaneously
    SELECT *
    INTO v_slot
    FROM public.slots
    WHERE id = p_slot_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slot does not exist';
    END IF;


    IF v_slot.is_available = false THEN
        RAISE EXCEPTION 'Slot is no longer available';
    END IF;


    -- Check whether this user already has an active booking
    IF EXISTS (
        SELECT 1
        FROM public.bookings
        WHERE slot_id = p_slot_id
        AND user_id = v_user_id
        AND booking_status IN ('pending', 'confirmed')
    ) THEN
        RAISE EXCEPTION 'You already have a booking for this slot';
    END IF;


    -- Create pending booking
    INSERT INTO public.bookings (
        slot_id,
        user_id,
        booking_status
    )
    VALUES (
        p_slot_id,
        v_user_id,
        'pending'
    )
    RETURNING *
    INTO v_booking;


    -- Make slot unavailable immediately
    UPDATE public.slots
    SET is_available = false
    WHERE id = p_slot_id;


    RETURN v_booking;

END;
$$;


GRANT EXECUTE
ON FUNCTION public.create_booking_request(UUID)
TO authenticated;


-- 5. Admin confirms or cancels booking
CREATE OR REPLACE FUNCTION public.admin_update_booking_status(
    p_booking_id UUID,
    p_status public.booking_status
)
RETURNS public.bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_booking public.bookings;
BEGIN

    IF NOT public.has_role(auth.uid(), 'admin') THEN
        RAISE EXCEPTION 'Only admins can update booking status';
    END IF;


    UPDATE public.bookings
    SET
        booking_status = p_status,
        updated_at = NOW()
    WHERE id = p_booking_id
    RETURNING *
    INTO v_booking;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found';
    END IF;


    -- If cancelled, make slot available again
    IF p_status = 'cancelled' THEN

        UPDATE public.slots
        SET is_available = true
        WHERE id = v_booking.slot_id;

    END IF;


    RETURN v_booking;

END;
$$;


GRANT EXECUTE
ON FUNCTION public.admin_update_booking_status(UUID, public.booking_status)
TO authenticated;


-- ============================================================
-- Booking indexes
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_slots_date
ON public.slots(date);

CREATE INDEX IF NOT EXISTS idx_slots_available
ON public.slots(is_available);

CREATE INDEX IF NOT EXISTS idx_bookings_user
ON public.bookings(user_id);

CREATE INDEX IF NOT EXISTS idx_bookings_status
ON public.bookings(booking_status);

CREATE INDEX IF NOT EXISTS idx_bookings_slot
ON public.bookings(slot_id);