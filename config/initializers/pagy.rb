require "pagy/extras/overflow"

# 24 cards per page; an out-of-range ?page= falls back to the last page.
Pagy::DEFAULT[:limit] = 24
Pagy::DEFAULT[:overflow] = :last_page
