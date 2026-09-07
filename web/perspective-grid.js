// VengeanceUI PerspectiveGrid Component (Converted to Vanilla ES Module)
// https://raw.githubusercontent.com/Ashutoshx7/VengeanceUI/main/public/r/perspective-grid.json

export function initPerspectiveGrid(container, options = {}) {
  if (!container) return null;

  const gridSize = options.gridSize || 36;
  const showOverlay = options.showOverlay !== undefined ? options.showOverlay : true;
  const fadeRadius = options.fadeRadius || 80;
  const fadeStop = options.fadeStop || '#070611';

  container.innerHTML = '';

  const plane = document.createElement('div');
  plane.className = 'perspective-grid-plane';
  plane.style.gridTemplateColumns = `repeat(${gridSize}, 1fr)`;
  plane.style.gridTemplateRows = `repeat(${gridSize}, 1fr)`;

  const totalTiles = gridSize * gridSize;
  const fragment = document.createDocumentFragment();

  for (let i = 0; i < totalTiles; i++) {
    const tile = document.createElement('div');
    tile.className = 'perspective-grid-tile';
    fragment.appendChild(tile);
  }
  plane.appendChild(fragment);
  container.appendChild(plane);

  if (showOverlay) {
    const overlay = document.createElement('div');
    overlay.className = 'perspective-grid-overlay';
    overlay.style.background = `radial-gradient(circle, transparent 25%, ${fadeStop} ${fadeRadius}%)`;
    container.appendChild(overlay);
  }

  // Interactive mouse illumination across tiles
  const handleMouseMove = (e) => {
    // Check if directly hovering over a tile or under pointer
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (el && el.classList && el.classList.contains('perspective-grid-tile')) {
      el.classList.add('active-tile');
      setTimeout(() => {
        el.classList.remove('active-tile');
      }, 60);
    }
  };

  window.addEventListener('mousemove', handleMouseMove, { passive: true });

  return {
    destroy() {
      window.removeEventListener('mousemove', handleMouseMove);
      container.innerHTML = '';
    }
  };
}
