# DockBar

## Tests before commit and push

Run the unit tests with coverage before every commit and before every push:

```bash
scripts/check-coverage.sh
```

Do not commit or push unless that command exits 0. Every test must pass, and line coverage of `Sources/DockBar` must stay at or above 70%.
