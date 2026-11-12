"""The detection rules and the fix types each one declares.

This describes the fix types to the model and lets the controller reject an undeclared one
early. It is not the enforcement: the database refuses anything fix.run() does not list
(erp/db/20-rules.sql).
"""

RULES = {
    "invoice_total_mismatch": {
        "description": "An invoice's total differs from the sum of unit_price * quantity over its lines.",
        # Facts handed to the model for one discrepancy, read with the agent's read-only role.
        "context": {
            "invoice": "SELECT invoice_id, total::float8, invoice_date::text FROM invoice WHERE invoice_id = $1",
            "lines": (
                "SELECT l.invoice_line_id, l.track_id, l.unit_price::float8, l.quantity, "
                "t.unit_price::float8 AS track_unit_price, (l.unit_price * l.quantity)::float8 AS line_total "
                "FROM invoice_line l JOIN track t USING (track_id) WHERE l.invoice_id = $1 ORDER BY 1"
            ),
        },
        "columns": {
            "invoice": ["invoice_id", "total", "invoice_date"],
            "lines": ["invoice_line_id", "track_id", "unit_price", "quantity", "track_unit_price", "line_total"],
        },
        "guidance": (
            "A line normally copies its track's unit_price, and customers buy one of each track, so quantity is "
            "normally 1. Find the single value that was changed: a line whose unit_price differs from "
            "track_unit_price, a line whose quantity is not 1, or, if every line looks normal, the invoice total."
        ),
        "fix_types": {
            "set_invoice_total_from_lines": {
                "description": "The lines are right and the invoice total is wrong: recompute the total from the lines.",
                "params": {},
            },
            "set_line_price_from_track": {
                "description": "One line's unit_price is wrong: reset it to the track's unit_price.",
                "params": {"invoice_line_id": "int"},
            },
            "set_line_quantity": {
                "description": "One line's quantity is wrong: set it to the given positive quantity.",
                "params": {"invoice_line_id": "int", "quantity": "int"},
            },
        },
    },
}
