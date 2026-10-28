gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local json = require "json"

local font = resource.load_font "font.ttf"
local logo = resource.load_image "logo.png"

local function texture(c)
  return resource.create_colored_texture(c[1], c[2], c[3], 1)
end

local function melange(c1, c2, t)
  return {c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t}
end

-- Couleurs : fond, texte et accent se reglent dans info-beamer (valeurs par
-- defaut ci-dessous) ; les autres teintes en sont deduites
local DEFAUT_FOND   = {0.08, 0.09, 0.12}   -- #14171F
local DEFAUT_TEXTE  = {1.00, 1.00, 1.00}   -- #FFFFFF
local DEFAUT_ACCENT = {0.97, 0.58, 0.12}   -- #F7941F

local tex_blanc = texture{1, 1, 1}
local FOND, FOND_UNE, TRAIT, ACCENT, TEXTE, TEXTE_2
local tex_fond, tex_fond_une, tex_trait, tex_accent

local function appliquer_couleurs(fond, texte, accent)
  FOND, TEXTE, ACCENT = fond, texte, accent
  FOND_UNE = melange(fond, {1, 1, 1}, 0.05)
  TRAIT    = melange(fond, {1, 1, 1}, 0.09)
  TEXTE_2  = melange(texte, fond, 0.25)
  for _, t in pairs{tex_fond or false, tex_fond_une or false, tex_trait or false, tex_accent or false} do
    if t then t:dispose() end
  end
  tex_fond, tex_fond_une = texture(FOND), texture(FOND_UNE)
  tex_trait, tex_accent  = texture(TRAIT), texture(ACCENT)
end

appliquer_couleurs(DEFAUT_FOND, DEFAUT_TEXTE, DEFAUT_ACCENT)

-- Couleur lue dans config.json ({r=, g=, b=, ...}), ou la valeur par defaut
local function couleur(c, defaut)
  if type(c) == "table" and tonumber(c.r) then return {c.r, c.g, c.b} end
  return defaut
end

-- Degrade de transparence : les lignes s'estompent en passant sous la une
local shader_fondu = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float r, g, b;
  uniform float vers_bas;   // 1 = opaque en haut, transparent en bas
  void main() {
    float a = vers_bas > 0.5 ? 1.0 - TexCoord.y : TexCoord.y;
    a = a * a * (3.0 - 2.0 * a);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a);
  }
]]

local LIGNES_VISIBLES = 8
local DUREE_UNE_FIXE  = 8       -- secondes par evenement a la une quand la liste ne defile pas
local DUREE_FONDU     = 0.7     -- fondu enchaine entre deux evenements a la une
local VITESSES = {               -- lignes par seconde
  ["1"] = 0.06, ["2"] = 0.10, ["3"] = 0.15, ["4"] = 0.22,
}

-- Reglages (modifiables depuis le tableau de bord info-beamer)
local titre    = "Strasbourg"
local vitesse  = VITESSES["2"]
local rotation = 90

util.json_watch("config.json", function(config)
  titre    = config.titre or titre
  vitesse  = VITESSES[tostring(config.vitesse)] or VITESSES["2"]
  rotation = tonumber(config.rotation) or 90
  appliquer_couleurs(couleur(config.couleur_fond, DEFAUT_FOND),
                     couleur(config.couleur_texte, DEFAUT_TEXTE),
                     couleur(config.couleur_accent, DEFAUT_ACCENT))
end)

-- Agenda ecrit par le service (agenda.json), absent au premier demarrage
local evenements = {}
local depart = sys.now()        -- debut du defilement, remis a zero a chaque mise a jour
local cache_textes = {}

local function lire_agenda()
  local ok, donnees = pcall(function()
    return json.decode(resource.load_file "agenda.json")
  end)
  if ok and type(donnees) == "table" and type(donnees.evenements) == "table" then
    evenements = donnees.evenements
    depart = sys.now()
    cache_textes = {}
  end
end

node.event("content_update", function(fichier)
  if fichier == "agenda.json" then lire_agenda() end
end)
lire_agenda()

-- Affiches : seules celles a l'ecran restent chargees en memoire
local affiches = {}

local function affiche(nom)
  if type(nom) ~= "string" then return nil end
  if not affiches[nom] then
    local ok, img = pcall(resource.load_image, nom)
    if not ok then return nil end
    affiches[nom] = img
  end
  return affiches[nom]
end

local function garder_affiches(utiles)
  for nom, img in pairs(affiches) do
    if not utiles[nom] then
      img:dispose()
      affiches[nom] = nil
    end
  end
end

------------------------------------------------------------------------
-- Texte
------------------------------------------------------------------------

local function ecrire(texte, x, y, taille, c, a)
  font:write(x, y, texte, taille, c[1], c[2], c[3], a or 1)
end

-- Raccourcit le texte avec "..." pour qu'il tienne dans la largeur
local function tronquer(texte, taille, largeur)
  local cle = texte .. "|" .. taille .. "|" .. largeur
  if cache_textes[cle] then return cache_textes[cle] end
  local r = texte
  if font:width(r, taille) > largeur then
    while #r > 0 and font:width(r .. "...", taille) > largeur do
      r = r:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")   -- retire un caractere UTF-8
    end
    r = r .. "..."
  end
  cache_textes[cle] = r
  return r
end

-- Decoupe le texte en "max" lignes au plus, la derniere raccourcie si besoin
local function couper(texte, taille, largeur, max)
  local lignes, ligne = {}, ""
  for mot in texte:gmatch("%S+") do
    local essai = ligne == "" and mot or ligne .. " " .. mot
    if ligne ~= "" and font:width(essai, taille) > largeur then
      lignes[#lignes + 1] = ligne
      ligne = mot
    else
      ligne = essai
    end
  end
  if ligne ~= "" then lignes[#lignes + 1] = ligne end
  if #lignes > max then
    lignes[max] = table.concat(lignes, " ", max)
    for i = #lignes, max + 1, -1 do lignes[i] = nil end
  end
  for i, l in ipairs(lignes) do lignes[i] = tronquer(l, taille, largeur) end
  return lignes
end

local function lieu(e)
  local t = e.salle or ""
  if e.ville and e.ville ~= "" then t = t .. " - " .. e.ville end
  return t
end

-- Etiquette : texte sur un fond colore ; renvoie sa largeur
local function etiquette(texte, x, y, taille, tex, c, a)
  local pad = taille * 0.4
  local w = font:width(texte, taille) + 2 * pad
  tex:draw(x, y, x + w, y + taille + 2 * pad, a)
  ecrire(texte, x + pad, y + pad, taille, c, a)
  return w
end

------------------------------------------------------------------------
-- Zones de l'ecran
------------------------------------------------------------------------

local function entete(W, H, h)
  tex_fond:draw(0, 0, W, h)
  local p = W * 0.05
  ecrire("AGENDA CULTUREL", p, h * 0.20, H * 0.016, ACCENT)
  ecrire(tronquer(titre, H * 0.042, W - 2 * p), p, h * 0.40, H * 0.042, TEXTE)
  tex_accent:draw(0, h - H * 0.004, W, h)
end

-- Contenu de la une (affiche et textes), avec une transparence pour le fondu
local function une(e, W, H, y0, h, a)
  if not e or a <= 0 then return end

  -- Affiche a gauche, dans un cadre 3:2
  local p  = W * 0.04
  local bw = W * 0.46
  local bh = math.min(bw / 1.5, h - 2 * p)
  local by = y0 + (h - bh) / 2
  tex_trait:draw(p, by, p + bw, by + bh, a)
  local img = affiche(e.affiche)
  if img and img:state() == "loaded" then
    local iw, ih = img:size()
    local f = math.min(bw / iw, bh / ih)
    local dw, dh = iw * f, ih * f
    img:draw(p + (bw - dw) / 2, by + (bh - dh) / 2, p + (bw + dw) / 2, by + (bh + dh) / 2, a)
  end

  -- Textes a droite
  local x = p + bw + p
  local larg = W - x - p
  local t_tag, t_titre, t_info = H * 0.014, H * 0.022, H * 0.016
  local y = by

  -- "A la une" puis le type de spectacle, a la ligne s'il ne tient pas
  local w = etiquette("À LA UNE", x, y, t_tag, tex_accent, FOND, a)
  local h_tag = t_tag * 1.8
  if type(e.type) == "string" then
    local w_type = font:width(e.type, t_tag) + t_tag * 0.8
    if w + t_tag * 0.5 + w_type <= larg then
      etiquette(e.type, x + w + t_tag * 0.5, y, t_tag, tex_trait, ACCENT, a)
    else
      y = y + h_tag + t_tag * 0.4
      etiquette(tronquer(e.type, t_tag, larg - t_tag), x, y, t_tag, tex_trait, ACCENT, a)
    end
  end
  y = y + h_tag + H * 0.010

  for _, l in ipairs(couper(e.titre or "", t_titre, larg, 3)) do
    ecrire(l, x, y, t_titre, TEXTE, a)
    y = y + t_titre * 1.15
  end
  y = y + H * 0.006
  for _, l in ipairs(couper(lieu(e), t_info, larg, 2)) do
    ecrire(l, x, y, t_info, TEXTE_2, a)
    y = y + t_info * 1.2
  end
  y = y + H * 0.006
  local quand = e.jour or ""
  if e.heure and e.heure ~= "" then quand = quand .. " à " .. e.heure end
  ecrire(tronquer(quand, t_info * 1.1, larg), x, y, t_info * 1.1, ACCENT, a)
  if type(e.fin) == "string" then
    y = y + t_info * 1.35
    ecrire(tronquer("jusqu'au " .. e.fin, t_info, larg), x, y, t_info, TEXTE_2, a)
  end
end

-- Texte reduit (jusqu'a 75 %) plutot que coupe, puis raccourci en dernier recours
local function ajuster(texte, taille, largeur)
  local w = font:width(texte, taille)
  if w > largeur then taille = math.max(taille * largeur / w, taille * 0.75) end
  return tronquer(texte, taille, largeur), taille
end

-- Une ligne de la liste, sur 3 niveaux :
--   date      TITRE
--   heure     SALLE - Ville
--             Type de spectacle  jusqu'au ...
local function ligne(e, W, y, h)
  local p = W * 0.04
  local t_date, t_heure = h * 0.28, h * 0.21
  local t1, t2, t3 = h * 0.21, h * 0.17, h * 0.15
  local y1, y2, y3 = y + h * 0.10, y + h * 0.40, y + h * 0.66

  ecrire(e.jour or "", p, y1, t_date, ACCENT)
  ecrire(e.heure or "", p, y1 + t_date * 1.2, t_heure, TEXTE_2)

  local x = p + font:width("mer. 30/12", t_date) + p * 0.8
  local larg = W - x - p
  ecrire(tronquer(e.titre or "", t1, larg), x, y1, t1, TEXTE)

  local texte, taille = ajuster(lieu(e), t2, larg)
  ecrire(texte, x, y2 + (t2 - taille) / 2, taille, TEXTE_2)

  local xs = x
  if type(e.type) == "string" then
    ecrire(e.type, xs, y3, t3, ACCENT)
    xs = xs + font:width(e.type, t3) + t3 * 0.8
  end
  if type(e.fin) == "string" then
    ecrire(tronquer("jusqu'au " .. e.fin, t3, x + larg - xs), xs, y3, t3, TEXTE_2)
  end

  tex_trait:draw(p, y + h - 2, W - p, y + h)
end

local function fondu(x1, y1, x2, y2, c, vers_bas)
  shader_fondu:use{r = c[1], g = c[2], b = c[3], vers_bas = vers_bas and 1 or 0}
  tex_blanc:draw(x1, y1, x2, y2)
  shader_fondu:deactivate()
end

local function pied(W, H, y0)
  tex_fond:draw(0, y0, W, H)
  tex_trait:draw(0, y0, W, y0 + 2)
  local h = H - y0
  local lh = h * 0.50
  local iw, ih = logo:size()
  local lw = lh * iw / ih
  local texte = "ESPACE CULTUREL"
  local t = h * 0.30
  local total = lw + h * 0.25 + font:width(texte, t)
  local x = (W - total) / 2
  logo:draw(x, y0 + (h - lh) / 2, x + lw, y0 + (h + lh) / 2)
  ecrire(texte, x + lw + h * 0.25, y0 + (h - t) / 2, t, TEXTE)
end

------------------------------------------------------------------------

-- Evenement a la une et fondu enchaine lors d'un changement
local une_actuelle, une_precedente, debut_fondu = nil, nil, 0

local function changer_une(e)
  if e ~= une_actuelle then
    une_precedente, une_actuelle = une_actuelle, e
    debut_fondu = sys.now()
  end
end

function node.render()
  gl.clear(FOND[1], FOND[2], FOND[3], 1)

  -- Ecran en portrait : on tourne le dessin
  local W, H = WIDTH, HEIGHT
  if rotation == 90 or rotation == 270 then W, H = HEIGHT, WIDTH end
  gl.translate(WIDTH / 2, HEIGHT / 2)
  gl.rotate(rotation, 0, 0, 1)
  gl.translate(-W / 2, -H / 2)

  local h_entete, h_une, h_pied = H * 0.09, H * 0.22, H * 0.07
  local y_liste = h_entete + h_une
  local y_pied = H - h_pied
  local h_ligne = (y_pied - y_liste) / LIGNES_VISIBLES

  local n = #evenements
  if n == 0 then
    entete(W, H, h_entete)
    local t = H * 0.02
    local msg = "Chargement de l'agenda..."
    ecrire(msg, (W - font:width(msg, t)) / 2, H * 0.45, t, TEXTE_2)
    pied(W, H, y_pied)
    return
  end

  -- Defilement continu de la liste ; l'evenement arrive en haut passe a la une
  local premier, decalage, i_une
  local ecoule = sys.now() - depart
  if n > LIGNES_VISIBLES then
    local y = (ecoule * vitesse * h_ligne) % (n * h_ligne)
    premier  = math.floor(y / h_ligne)
    decalage = y - premier * h_ligne
    i_une    = math.floor(y / h_ligne + 0.5) % n
  else
    premier, decalage = 0, 0
    i_une = math.floor(ecoule / DUREE_UNE_FIXE) % n
  end

  local a_montrer = math.min(n, LIGNES_VISIBLES + 1)
  for k = 0, a_montrer - 1 do
    ligne(evenements[(premier + k) % n + 1], W, y_liste + k * h_ligne - decalage, h_ligne)
  end

  -- Les lignes s'estompent en passant sous la une, et un peu avant le pied
  fondu(0, y_liste, W, y_liste + h_ligne * 0.9, FOND, true)
  fondu(0, y_pied - h_ligne * 0.35, W, y_pied, FOND, false)

  -- En-tete, une et pied recouvrent les lignes qui sortent de la liste
  entete(W, H, h_entete)
  tex_fond_une:draw(0, h_entete, W, y_liste)
  changer_une(evenements[i_une + 1])
  local t = math.min((sys.now() - debut_fondu) / DUREE_FONDU, 1)
  if t < 1 then une(une_precedente, W, H, h_entete, h_une, 1 - t) end
  une(une_actuelle, W, H, h_entete, h_une, t)
  pied(W, H, y_pied)

  -- Affiches gardees en memoire : la une, la precedente (fondu) et la suivante
  local suivant = evenements[(i_une + 1) % n + 1]
  local utiles = {}
  for _, e in pairs{une_actuelle, une_precedente or false, suivant} do
    if type(e) == "table" and type(e.affiche) == "string" then utiles[e.affiche] = true end
  end
  affiche(suivant.affiche)
  garder_affiches(utiles)
end
