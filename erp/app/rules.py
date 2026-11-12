"""The detection rules and the fix types each one declares.

This describes the fix types to the model and lets the controller reject an undeclared one
early. It is not the enforcement: the database refuses anything fix.run() does not list
(erp/db/20-rules.sql).
"""

RULES = {
    "invoice_total_mismatch": {
        "description": "An invoice's total differs from the sum of unit_price * quantity over its lines.",
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
