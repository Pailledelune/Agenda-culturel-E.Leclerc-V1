gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local json = require "json"

local font = resource.load_font "font.ttf"
local logo = resource.load_image "logo-espace-culturel.png"

local function texture(c)
  return resource.create_colored_texture(c[1], c[2], c[3], 1)
end

local function melange(c1, c2, t)
  return {c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t}
end

-- Couleurs fixes (volontairement non reglables dans info-beamer)
local FOND_CADRE = {0.08, 0.09, 0.12}      -- #14171F : en-tete et pied
local FOND_LISTE = {0.08, 0.09, 0.12}      -- #14171F : liste
local FOND_UNE   = {0.126, 0.136, 0.164}   -- #20232A : une
local TEXTE      = {1.00, 1.00, 1.00}      -- #FFFFFF
local ACCENT     = {0.97, 0.58, 0.12}      -- #F7941F
local TRAIT      = melange(FOND_LISTE, {1, 1, 1}, 0.09)
local TEXTE_2    = melange(TEXTE, FOND_LISTE, 0.25)

local tex_blanc  = texture{1, 1, 1}
local tex_cadre  = texture(FOND_CADRE)
local tex_une    = texture(FOND_UNE)
local tex_trait  = texture(TRAIT)
local tex_accent = texture(ACCENT)

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

local LIGNES_DEFAUT   = 15
local DUREE_UNE_FIXE  = 8       -- secondes par evenement a la une quand la liste ne defile pas
local DUREE_FONDU     = 0.7     -- fondu enchaine entre deux evenements a la une
-- Pixels par image (ecran de 1920 de haut, 60 images par seconde). Des
-- fractions simples donnent une cadence parfaitement reguliere : 1/2 = un
-- pixel toutes les 2 images, 1/3 = toutes les 3 images, etc.
local VITESSES = {
  ["1"] = 1 / 4,    -- tres lente : 15 pixels par seconde
  ["2"] = 1 / 3,    -- lente      : 20 pixels par seconde
  ["3"] = 1 / 2,    -- normale    : 30 pixels par seconde
  ["4"] = 1,        -- rapide     : 60 pixels par seconde
}

-- Reglages (modifiables depuis le tableau de bord info-beamer)
local titre    = "Strasbourg"
local vitesse  = VITESSES["2"]
local rotation = 90
local lignes   = LIGNES_DEFAUT

util.json_watch("config.json", function(config)
  titre    = config.titre or titre
  vitesse  = VITESSES[tostring(config.vitesse)] or VITESSES["2"]
  rotation = tonumber(config.rotation) or 90
  lignes   = math.min(math.max(math.floor(tonumber(config.lignes) or LIGNES_DEFAUT), 6), 20)
end)

-- Agenda ecrit par le service (agenda.json), absent au premier demarrage
local evenements = {}
local depart = sys.now()        -- debut du defilement, remis a zero a chaque mise a jour
local position = 0              -- defilement en pixels, avance d'un pas fixe a chaque image
local cache_textes = {}

local function lire_agenda()
  local ok, donnees = pcall(function()
    return json.decode(resource.load_file "agenda.json")
  end)
  if ok and type(donnees) == "table" and type(donnees.evenements) == "table" then
    evenements = donnees.evenements
    depart = sys.now()
    position = 0
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

-- En-tete : titre a gauche, logo Espace culturel a droite ; le titre
-- s'arrete avant le logo (raccourci s'il est trop long)
local function entete(W, H, h)
  tex_cadre:draw(0, 0, W, h)
  local p = W * 0.05

  local iw, ih = logo:size()
  local lh = h * 0.70
  local lw = lh * iw / ih
  local lx = W - W * 0.04 - lw
  logo:draw(lx, (h - lh) / 2 - H * 0.002, lx + lw, (h + lh) / 2 - H * 0.002)

  local larg = lx - W * 0.03 - p
  ecrire("AGENDA CULTUREL", p, h * 0.20, H * 0.016, ACCENT)
  ecrire(tronquer(titre, H * 0.042, larg), p, h * 0.40, H * 0.042, TEXTE)
  tex_accent:draw(0, h - H * 0.004, W, h)
end

-- La mise en page de chaque evenement (decoupage, raccourcis, positions) est
-- calculee une seule fois puis gardee : a chaque image il ne reste qu'a
-- dessiner, ce qui rend le defilement plus regulier.

local function mise_en_page_une(e, W, H, h)
  local m = e._une
  if m and m.W == W and m.H == H then return m end
  m = {W = W, H = H}

  local p  = W * 0.04
  m.bw = W * 0.46
  m.bh = math.min(m.bw / 1.5, h - 2 * p)
  m.x  = p + m.bw + p
  local larg = W - m.x - p
  m.t_tag, m.t_titre, m.t_info = H * 0.014, H * 0.022, H * 0.016

  -- "A la une" puis le type de spectacle, a la ligne s'il ne tient pas
  local w_une = font:width("À LA UNE", m.t_tag) + m.t_tag * 0.8
  m.h_tag = m.t_tag * 1.8
  local y = 0
  if type(e.type) == "string" then
    local w_type = font:width(e.type, m.t_tag) + m.t_tag * 0.8
    if w_une + m.t_tag * 0.5 + w_type <= larg then
      m.type, m.type_x, m.type_y = e.type, w_une + m.t_tag * 0.5, 0
    else
      y = m.h_tag + m.t_tag * 0.4
      m.type, m.type_x, m.type_y = tronquer(e.type, m.t_tag, larg - m.t_tag), 0, y
    end
  end
  y = y + m.h_tag + H * 0.010

  m.textes = {}
  local function ajouter(texte, taille, c)
    m.textes[#m.textes + 1] = {texte, y, taille, c}
  end
  for _, l in ipairs(couper(e.titre or "", m.t_titre, larg, 3)) do
    ajouter(l, m.t_titre, "texte")
    y = y + m.t_titre * 1.15
  end
  y = y + H * 0.006
  for _, l in ipairs(couper(lieu(e), m.t_info, larg, 2)) do
    ajouter(l, m.t_info, "texte_2")
    y = y + m.t_info * 1.2
  end
  y = y + H * 0.006
  local quand = e.jour or ""
  if e.heure and e.heure ~= "" then quand = quand .. " à " .. e.heure end
  ajouter(tronquer(quand, m.t_info * 1.1, larg), m.t_info * 1.1, "accent")
  if type(e.fin) == "string" then
    y = y + m.t_info * 1.35
    ajouter(tronquer("jusqu'au " .. e.fin, m.t_info, larg), m.t_info, "texte_2")
  end

  e._une = m
  return m
end

-- Contenu de la une (affiche et textes), avec une transparence pour le fondu
local function une(e, W, H, y0, h, a)
  if not e or a <= 0 then return end
  local m = mise_en_page_une(e, W, H, h)

  -- Affiche a gauche, dans un cadre 3:2
  local p  = W * 0.04
  local by = y0 + (h - m.bh) / 2
  tex_trait:draw(p, by, p + m.bw, by + m.bh, a)
  local img = affiche(e.affiche)
  if img and img:state() == "loaded" then
    local iw, ih = img:size()
    local f = math.min(m.bw / iw, m.bh / ih)
    local dw, dh = iw * f, ih * f
    img:draw(p + (m.bw - dw) / 2, by + (m.bh - dh) / 2, p + (m.bw + dw) / 2, by + (m.bh + dh) / 2, a)
  end

  -- Textes a droite
  local couleurs = {texte = TEXTE, texte_2 = TEXTE_2, accent = ACCENT}
  etiquette("À LA UNE", m.x, by, m.t_tag, tex_accent, FOND_CADRE, a)
  if m.type then
    etiquette(m.type, m.x + m.type_x, by + m.type_y, m.t_tag, tex_trait, ACCENT, a)
  end
  for _, t in ipairs(m.textes) do
    ecrire(t[1], m.x, by + t[2], t[3], couleurs[t[4]], a)
  end
end

-- Texte reduit (jusqu'a 75 %) plutot que coupe, puis raccourci en dernier recours
local function ajuster(texte, taille, largeur)
  local w = font:width(texte, taille)
  if w > largeur then taille = math.max(taille * largeur / w, taille * 0.75) end
  return tronquer(texte, taille, largeur), taille
end

-- Une ligne de la liste, sur 2 niveaux :
--   date   TITRE
--   heure  SALLE - Ville                    Type de spectacle  jusqu'au ...
-- Le texte est plafonne a sa taille pour 12 lignes : avec moins de lignes,
-- elles sont simplement plus espacees.
local function mise_en_page_ligne(e, W, H, h)
  local m = e._ligne
  if m and m.W == W and m.h == h then return m end
  m = {W = W, h = h}

  local p = W * 0.04
  local t1 = math.min(h * 0.36, H * 0.0185)
  local t2 = math.min(h * 0.27, H * 0.0140)
  local bloc = t1 * 1.22 + t2
  m.t1, m.t2 = t1, t2
  -- Positions arrondies au pixel : le texte reste net en defilant
  m.y1 = math.floor((h - bloc) / 2 + 0.5)
  m.y2 = math.floor(m.y1 + t1 * 1.22 + 0.5)

  m.x = math.floor(p + font:width("mer. 30/12", t1) + p * 0.6 + 0.5)
  m.titre = tronquer(e.titre or "", t1, W - m.x - p)

  -- A droite : type de spectacle colle au bord (tous alignes), precede de
  -- "jusqu'au ..." ; jamais coupes
  local droite = W - p
  if type(e.type) == "string" then
    droite = math.floor(droite - font:width(e.type, t2))
    m.type_x = droite
    droite = droite - t2 * 0.9
  end
  if type(e.fin) == "string" then
    m.fin = "jusqu'au " .. e.fin
    droite = math.floor(droite - font:width(m.fin, t2))
    m.fin_x = droite
    droite = droite - t2 * 0.9
  end

  -- Salle et ville dans la place restante (reduites si besoin)
  m.lieu, m.t_lieu = ajuster(lieu(e), t2, droite - m.x)
  m.lieu_dy = math.floor((t2 - m.t_lieu) / 2 + 0.5)

  e._ligne = m
  return m
end

local function ligne(e, W, H, y, h)
  local m = mise_en_page_ligne(e, W, H, h)
  local p = W * 0.04

  ecrire(e.jour or "", p, y + m.y1, m.t1, ACCENT)
  ecrire(e.heure or "", p, y + m.y2, m.t2, TEXTE_2)
  ecrire(m.titre, m.x, y + m.y1, m.t1, TEXTE)
  if m.fin then ecrire(m.fin, m.fin_x, y + m.y2, m.t2, TEXTE_2) end
  if m.type_x then ecrire(e.type, m.type_x, y + m.y2, m.t2, ACCENT) end
  ecrire(m.lieu, m.x, y + m.y2 + m.lieu_dy, m.t_lieu, TEXTE_2)

  local bas = math.floor(y + h + 0.5)
  tex_trait:draw(p, bas - 2, W - p, bas)
end

local function fondu(x1, y1, x2, y2, c, vers_bas)
  shader_fondu:use{r = c[1], g = c[2], b = c[3], vers_bas = vers_bas and 1 or 0}
  tex_blanc:draw(x1, y1, x2, y2)
  shader_fondu:deactivate()
end

local function pied(W, H, y0)
  tex_cadre:draw(0, y0, W, H)
  tex_trait:draw(0, y0, W, y0 + 2)
  local h = H - y0
  local t1, t2 = "Billetterie Ticketmaster", "accueil ESPACE CULTUREL"
  local t = h * 0.32
  local espace = t * 0.5
  local total = font:width(t1, t) + espace + font:width(t2, t)
  if total > W * 0.92 then
    t = t * W * 0.92 / total
    espace = t * 0.5
    total = font:width(t1, t) + espace + font:width(t2, t)
  end
  local x = (W - total) / 2
  local y = y0 + (h - t) / 2
  ecrire(t1, x, y, t, ACCENT)
  ecrire(t2, x + font:width(t1, t) + espace, y, t, TEXTE)
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
  gl.clear(FOND_LISTE[1], FOND_LISTE[2], FOND_LISTE[3], 1)

  -- Ecran en portrait : on tourne le dessin
  local W, H = WIDTH, HEIGHT
  if rotation == 90 or rotation == 270 then W, H = HEIGHT, WIDTH end
  gl.translate(WIDTH / 2, HEIGHT / 2)
  gl.rotate(rotation, 0, 0, 1)
  gl.translate(-W / 2, -H / 2)

  local h_entete, h_une, h_pied = H * 0.09, H * 0.22, H * 0.07
  local y_liste = h_entete + h_une
  local y_pied = H - h_pied
  local h_ligne = (y_pied - y_liste) / lignes

  local n = #evenements
  if n == 0 then
    entete(W, H, h_entete)
    local t = H * 0.02
    local msg = "Chargement de l'agenda..."
    ecrire(msg, (W - font:width(msg, t)) / 2, H * 0.45, t, TEXTE_2)
    pied(W, H, y_pied)
    return
  end

  -- Defilement continu de la liste ; l'evenement arrive en haut passe a la une.
  -- La liste avance d'un pas fixe a chaque image (60 par seconde) et est
  -- dessinee sur des pixels entiers : le mouvement garde une cadence reguliere
  -- au lieu de suivre l'horloge, dont les petits ecarts d'une image a l'autre
  -- se voient sur un texte qui defile lentement.
  local premier, y, i_une
  if n > lignes then
    position = (position + vitesse * H / 1920) % (n * h_ligne)
    y = math.floor(position + 0.5)
    premier = math.floor(y / h_ligne)
    i_une   = math.floor(y / h_ligne + 0.5) % n
  else
    premier, y = 0, 0
    i_une = math.floor((sys.now() - depart) / DUREE_UNE_FIXE) % n
  end

  local a_montrer = math.min(n, lignes + 1)
  for k = 0, a_montrer - 1 do
    local haut = math.floor(y_liste + (premier + k) * h_ligne + 0.5) - y
    ligne(evenements[(premier + k) % n + 1], W, H, haut, h_ligne)
  end

  -- Les lignes s'estompent en passant sous la une, et un peu avant le pied
  fondu(0, y_liste, W, y_liste + h_ligne * 0.9, FOND_LISTE, true)
  fondu(0, y_pied - h_ligne * 0.35, W, y_pied, FOND_LISTE, false)

  -- En-tete, une et pied recouvrent les lignes qui sortent de la liste
  entete(W, H, h_entete)
  tex_une:draw(0, h_entete, W, y_liste)
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
