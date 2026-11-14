<#
.SYNOPSIS
Creates, builds, and runs the "Snake Express" WinForms game using Native XInput & Keyboard.
Outputs all compilation data to Build.log.
#>

$ErrorActionPreference = "Stop"

$ProjectFolder = "SnakeExpress"
$Configuration = "Release"

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
$targetRoot = Join-Path $scriptDir $ProjectFolder
$logFile = Join-Path $targetRoot "Build.log"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: dotnet CLI not found. Install .NET SDK." -ForegroundColor Red
    exit 1
}

# 1. Clean Workspace
if (Test-Path $targetRoot) {
    Write-Host "Clearing existing project directory..." -ForegroundColor Yellow
    Remove-Item -Path $targetRoot -Recurse -Force
}

Write-Host "Creating new WinForms project in $targetRoot" -ForegroundColor Cyan
& dotnet new winforms -o $targetRoot -n $ProjectFolder | Out-Null

Set-Location $targetRoot

# 2. Add Dependencies
Write-Host "Adding NuGet packages (SharpDX.XInput, Newtonsoft.Json)..." -ForegroundColor Cyan
& dotnet add package SharpDX.XInput --version 4.2.0 | Out-Null
& dotnet add package Newtonsoft.Json --version 13.0.3 | Out-Null

function Write-File([string]$fileName, [string]$content) {
    $fullPath = Join-Path $targetRoot $fileName
    Set-Content -Path $fullPath -Value $content -Encoding UTF8
}

# 3. Write C# Source Files

Write-File "Program.cs" @'
using System;
using System.Windows.Forms;

namespace SnakeExpress
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new GameForm());
        }
    }
}
'@

Write-File "InputEngine.cs" @'
using System;
using SharpDX.XInput;

namespace SnakeExpress
{
    public class InputEngine
    {
        private Controller[] controllers;
        private State[] prevStates;

        public InputEngine()
        {
            controllers = new Controller[4];
            prevStates = new State[4];
            for (int i = 0; i < 4; i++)
            {
                controllers[i] = new Controller((UserIndex)i);
                prevStates[i] = new State();
            }
        }

        public void Update(Action<int, GamepadButtonFlags> onButtonDown)
        {
            for (int i = 0; i < 4; i++)
            {
                if (!controllers[i].IsConnected) continue;

                var state = controllers[i].GetState();
                var curButtons = state.Gamepad.Buttons;
                var prevButtons = prevStates[i].Gamepad.Buttons;

                foreach (GamepadButtonFlags flag in Enum.GetValues(typeof(GamepadButtonFlags)))
                {
                    if (flag == 0) continue;
                    bool wasDown = prevButtons.HasFlag(flag);
                    bool isDown = curButtons.HasFlag(flag);

                    if (!wasDown && isDown)
                    {
                        onButtonDown?.Invoke(i, flag);
                    }
                }
                prevStates[i] = state;
            }
        }
    }
}
'@

Write-File "GameConfig.cs" @'
using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;

namespace SnakeExpress
{
    public class GameConfig
    {
        public bool Fullscreen { get; set; } = false;
        public int ResWidth { get; set; } = 1280;
        public int ResHeight { get; set; } = 720;
        public Dictionary<int, int> PlayerWins { get; set; } = new Dictionary<int, int>();

        public static GameConfig Load()
        {
            try
            {
                if (File.Exists("config.json"))
                    return JsonConvert.DeserializeObject<GameConfig>(File.ReadAllText("config.json")) ?? new GameConfig();
            }
            catch { }
            return new GameConfig();
        }

        public void Save()
        {
            try
            {
                File.WriteAllText("config.json", JsonConvert.SerializeObject(this, Formatting.Indented));
            }
            catch { }
        }

        public int GetWins(int playerIndex)
        {
            return PlayerWins.ContainsKey(playerIndex) ? PlayerWins[playerIndex] : 0;
        }

        public void AddWin(int playerIndex)
        {
            if (!PlayerWins.ContainsKey(playerIndex)) PlayerWins[playerIndex] = 0;
            PlayerWins[playerIndex]++;
            Save();
        }
    }
}
'@

Write-File "GameForm.cs" @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;
using SharpDX.XInput;

namespace SnakeExpress
{
    public enum GameState { MainMenu, Settings, HowToPlay, Lobby, Playing, GameOver }
    public enum GameMode { Survival, FirstTo, Classic1P, Rush }
    public enum PowerUpType { Food, Speed, LockDown, ColourChanger, TP, Destruction, Bomb }
    public enum PlayerType { None, HumanKeyboard, HumanGamepad, BotEasy, BotNormal, BotHard }

    public class SnakePlayer
    {
        public int Index;
        public PlayerType Type = PlayerType.None;
        public bool IsAlive;
        public Color SnakeColor;
        public List<Point> Body = new List<Point>();
        public Point Direction;
        public Point NextDirection;
        public int Score => Body.Count * 5;
        public int SpeedBoostTimer;
        public int DestructionTimer;
    }

    public class PowerUp { public Point Position; public PowerUpType Type; }
    
    public class FloatingText { 
        public string Text; 
        public float X, Y; 
        public int TicksLeft; 
        public Color Color; 
    }

    public class GameForm : Form
    {
        const int GridSize = 25;
        const int GridWidth = 51;
        const int GridHeight = 28;
        const int UIHeightOffset = 2;

        GameState currentState = GameState.MainMenu;
        GameMode currentMode = GameMode.Survival;
        int targetScore = 50;

        InputEngine inputEngine;
        System.Windows.Forms.Timer gameLoop;
        GameConfig config;

        SnakePlayer[] players;
        List<PowerUp> powerUps = new List<PowerUp>();
        List<FloatingText> fxList = new List<FloatingText>();
        
        int lockDownTimer = 0;
        int globalTickCounter = 0;
        string gameOverMessage = "";
        
        int menuSelectionIndex = 0;
        int lobbySelectionIndex = 0;
        string[] resOptions = { "1280x720", "1366x768", "1600x900", "1920x1080" };

        Color[] defaultColors = { Color.Red, Color.Green, Color.Blue, Color.Orange };

        Dictionary<int, List<Color>> unlockableColors = new Dictionary<int, List<Color>> {
            { 0, new List<Color> { Color.Crimson, Color.DarkRed } },
            { 1, new List<Color> { Color.LimeGreen, Color.SpringGreen } },
            { 2, new List<Color> { Color.DodgerBlue, Color.DeepSkyBlue } },
            { 3, new List<Color> { Color.DarkOrange, Color.Gold } }
        };

        public GameForm()
        {
            this.Text = "Snake Express";
            this.DoubleBuffered = true;
            this.BackColor = Color.FromArgb(15, 15, 15);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.KeyPreview = true;

            config = GameConfig.Load();
            ApplyResolutionSettings();

            inputEngine = new InputEngine();
            
            players = new SnakePlayer[4];
            for (int i = 0; i < 4; i++)
            {
                players[i] = new SnakePlayer { Index = i, SnakeColor = defaultColors[i] };
            }

            // Default Player 1 to Keyboard if none configured yet
            players[0].Type = PlayerType.HumanKeyboard;

            gameLoop = new System.Windows.Forms.Timer { Interval = 16 }; 
            gameLoop.Tick += GameLoop_Tick;
            gameLoop.Start();
        }

        private void ApplyResolutionSettings()
        {
            this.FormBorderStyle = config.Fullscreen ? FormBorderStyle.None : FormBorderStyle.FixedDialog;
            this.WindowState = config.Fullscreen ? FormWindowState.Maximized : FormWindowState.Normal;
            if (!config.Fullscreen)
            {
                this.ClientSize = new Size(config.ResWidth, config.ResHeight);
                this.CenterToScreen();
            }
        }

        private void GameLoop_Tick(object sender, EventArgs e)
        {
            inputEngine.Update(OnGamepadButton);

            if (currentState == GameState.Playing)
            {
                globalTickCounter++;
                UpdateGameLogic();
            }

            this.Invalidate();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);

            if (currentState == GameState.MainMenu)
            {
                if (e.KeyCode == Keys.Down || e.KeyCode == Keys.S) { menuSelectionIndex = (menuSelectionIndex + 1) % 4; Invalidate(); }
                if (e.KeyCode == Keys.Up || e.KeyCode == Keys.W) { menuSelectionIndex--; if (menuSelectionIndex < 0) menuSelectionIndex = 3; Invalidate(); }
                if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
                {
                    ExecuteMenuSelection();
                }
            }
            else if (currentState == GameState.Settings)
            {
                if (e.KeyCode == Keys.B || e.KeyCode == Keys.Escape) { currentState = GameState.MainMenu; menuSelectionIndex = 1; Invalidate(); }
            }
            else if (currentState == GameState.HowToPlay)
            {
                if (e.KeyCode == Keys.B || e.KeyCode == Keys.Escape || e.KeyCode == Keys.Enter) { currentState = GameState.MainMenu; menuSelectionIndex = 2; Invalidate(); }
            }
            else if (currentState == GameState.Playing)
            {
                foreach (var p in players)
                {
                    if (p.Type == PlayerType.HumanKeyboard && p.IsAlive)
                    {
                        if ((e.KeyCode == Keys.Up || e.KeyCode == Keys.W) && p.Direction.Y == 0) p.NextDirection = new Point(0, -1);
                        if ((e.KeyCode == Keys.Down || e.KeyCode == Keys.S) && p.Direction.Y == 0) p.NextDirection = new Point(0, 1);
                        if ((e.KeyCode == Keys.Left || e.KeyCode == Keys.A) && p.Direction.X == 0) p.NextDirection = new Point(-1, 0);
                        if ((e.KeyCode == Keys.Right || e.KeyCode == Keys.D) && p.Direction.X == 0) p.NextDirection = new Point(1, 0);
                    }
                }
            }
            else if (currentState == GameState.GameOver)
            {
                if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space || e.KeyCode == Keys.B)
                {
                    currentState = GameState.Lobby;
                    menuSelectionIndex = 0;
                    Invalidate();
                }
            }
        }

        private void ExecuteMenuSelection()
        {
            if (menuSelectionIndex == 0) { currentState = GameState.Lobby; lobbySelectionIndex = 0; }
            else if (menuSelectionIndex == 1) { currentState = GameState.Settings; menuSelectionIndex = 0; }
            else if (menuSelectionIndex == 2) { currentState = GameState.HowToPlay; }
            else if (menuSelectionIndex == 3) { Application.Exit(); }
            Invalidate();
        }

        private void OnGamepadButton(int pIndex, GamepadButtonFlags btn)
        {
            if (currentState == GameState.MainMenu)
            {
                if (btn == GamepadButtonFlags.DPadDown) { menuSelectionIndex = (menuSelectionIndex + 1) % 4; Invalidate(); }
                if (btn == GamepadButtonFlags.DPadUp) { menuSelectionIndex--; if (menuSelectionIndex < 0) menuSelectionIndex = 3; Invalidate(); }
                if (btn == GamepadButtonFlags.A || btn == GamepadButtonFlags.Start)
                {
                    ExecuteMenuSelection();
                }
                return;
            }
            
            if (currentState == GameState.Settings)
            {
                if (btn == GamepadButtonFlags.B) { currentState = GameState.MainMenu; menuSelectionIndex = 1; }
                return;
            }

            if (currentState == GameState.HowToPlay)
            {
                if (btn == GamepadButtonFlags.B || btn == GamepadButtonFlags.A) { currentState = GameState.MainMenu; menuSelectionIndex = 2; }
                return;
            }

            if (currentState == GameState.Lobby)
            {
                if (btn == GamepadButtonFlags.B) { currentState = GameState.MainMenu; menuSelectionIndex = 0; return; }

                if (btn == GamepadButtonFlags.DPadDown) lobbySelectionIndex = (lobbySelectionIndex + 1) % 6;
                if (btn == GamepadButtonFlags.DPadUp) { lobbySelectionIndex--; if (lobbySelectionIndex < 0) lobbySelectionIndex = 5; }

                if (lobbySelectionIndex < 4)
                {
                    int slot = lobbySelectionIndex;
                    if (btn == GamepadButtonFlags.DPadLeft || btn == GamepadButtonFlags.DPadRight)
                    {
                        int t = (int)players[slot].Type;
                        t += btn == GamepadButtonFlags.DPadRight ? 1 : -1;
                        if (t > 5) t = 0; if (t < 0) t = 5;
                        PlayerType oldType = players[slot].Type;
                        players[slot].Type = (PlayerType)t;

                        if (oldType == PlayerType.None && players[slot].Type != PlayerType.None)
                        {
                            AssignUniqueColor(slot);
                        }
                    }
                    if (btn == GamepadButtonFlags.A && players[slot].Type != PlayerType.None)
                    {
                        CycleUniqueColor(slot);
                    }
                }
                else if (lobbySelectionIndex == 4)
                {
                    if (btn == GamepadButtonFlags.DPadLeft || btn == GamepadButtonFlags.DPadRight || btn == GamepadButtonFlags.A)
                    {
                        int m = (int)currentMode + (btn == GamepadButtonFlags.DPadLeft ? -1 : 1);
                        if (m > 3) m = 0; if (m < 0) m = 3;
                        currentMode = (GameMode)m;
                    }
                }
                else if (lobbySelectionIndex == 5 && currentMode == GameMode.FirstTo)
                {
                    if (btn == GamepadButtonFlags.DPadLeft || btn == GamepadButtonFlags.DPadRight || btn == GamepadButtonFlags.A)
                    {
                        targetScore += btn == GamepadButtonFlags.DPadRight ? 50 : -50;
                        if (targetScore < 50) targetScore = 50;
                    }
                }

                if (btn == GamepadButtonFlags.Start && players.Any(p => p.Type != PlayerType.None))
                {
                    StartGame();
                }
                return;
            }

            if (currentState == GameState.Playing)
            {
                // Map gamepad to player if type is HumanGamepad
                int gamepadAssignedCount = 0;
                for (int i = 0; i < 4; i++)
                {
                    if (players[i].Type == PlayerType.HumanGamepad)
                    {
                        if (gamepadAssignedCount == pIndex)
                        {
                            var p = players[i];
                            if (!p.IsAlive) return;

                            if (btn == GamepadButtonFlags.DPadUp && p.Direction.Y == 0) p.NextDirection = new Point(0, -1);
                            if (btn == GamepadButtonFlags.DPadDown && p.Direction.Y == 0) p.NextDirection = new Point(0, 1);
                            if (btn == GamepadButtonFlags.DPadLeft && p.Direction.X == 0) p.NextDirection = new Point(-1, 0);
                            if (btn == GamepadButtonFlags.DPadRight && p.Direction.X == 0) p.NextDirection = new Point(1, 0);
                            break;
                        }
                        gamepadAssignedCount++;
                    }
                }
            }
            
            if (currentState == GameState.GameOver)
            {
                if (btn == GamepadButtonFlags.Start || btn == GamepadButtonFlags.A || btn == GamepadButtonFlags.B)
                {
                    currentState = GameState.Lobby;
                    menuSelectionIndex = 0;
                }
            }
        }

        private void AssignUniqueColor(int slot)
        {
            var takenColors = players.Where(pl => pl.Type != PlayerType.None && pl.Index != slot).Select(pl => pl.SnakeColor).ToList();
            List<Color> pool = new List<Color>(defaultColors);
            if (config.GetWins(slot) > 0 && unlockableColors.ContainsKey(slot)) pool.AddRange(unlockableColors[slot]);

            foreach (var col in pool)
            {
                if (!takenColors.Contains(col))
                {
                    players[slot].SnakeColor = col;
                    return;
                }
            }
        }

        private void CycleUniqueColor(int slot)
        {
            var takenColors = players.Where(pl => pl.Type != PlayerType.None && pl.Index != slot).Select(pl => pl.SnakeColor).ToList();
            List<Color> pool = new List<Color>(defaultColors);
            if (config.GetWins(slot) > 0 && unlockableColors.ContainsKey(slot)) pool.AddRange(unlockableColors[slot]);

            int curIdx = pool.IndexOf(players[slot].SnakeColor);
            for (int step = 1; step <= pool.Count; step++)
            {
                int nextIdx = (curIdx + step) % pool.Count;
                Color candidate = pool[nextIdx];
                if (!takenColors.Contains(candidate))
                {
                    players[slot].SnakeColor = candidate;
                    break;
                }
            }
        }

        private string GetColorName(Color c)
        {
            if (c == Color.Red || c == Color.Crimson || c == Color.DarkRed) return "Red";
            if (c == Color.Green || c == Color.LimeGreen || c == Color.SpringGreen) return "Green";
            if (c == Color.Blue || c == Color.DodgerBlue || c == Color.DeepSkyBlue) return "Blue";
            if (c == Color.Orange || c == Color.DarkOrange || c == Color.Gold) return "Orange";
            return "Custom";
        }

        private void StartGame()
        {
            powerUps.Clear();
            fxList.Clear();
            lockDownTimer = 0;
            globalTickCounter = 0;
            
            Point[] spawns = { new Point(10, 10), new Point(GridWidth - 10, GridHeight - 10), new Point(10, GridHeight - 10), new Point(GridWidth - 10, 10) };
            Point[] dirs = { new Point(1, 0), new Point(-1, 0), new Point(1, 0), new Point(-1, 0) };

            for (int i = 0; i < 4; i++)
            {
                var p = players[i];
                if (p.Type == PlayerType.None) continue;
                
                p.IsAlive = true;
                p.SpeedBoostTimer = 0;
                p.DestructionTimer = 0;
                p.Body.Clear();
                p.Direction = dirs[i];
                p.NextDirection = dirs[i];

                for (int j = 0; j < 3; j++) p.Body.Add(new Point(spawns[i].X - (j * dirs[i].X), spawns[i].Y));
            }

            SpawnPowerUp(PowerUpType.Food);
            currentState = GameState.Playing;
        }

        private void UpdateGameLogic()
        {
            int standardBaseTickRate = 6;

            foreach (var p in players)
            {
                if (p.Type == PlayerType.None || !p.IsAlive) continue;

                if (p.Type == PlayerType.BotEasy || p.Type == PlayerType.BotNormal || p.Type == PlayerType.BotHard)
                {
                    if (globalTickCounter % standardBaseTickRate == 0) CalculateBotMove(p);
                }

                int pTickRate = standardBaseTickRate;
                if (currentMode == GameMode.Rush)
                {
                    int speedIncrease = p.Body.Count / 3;
                    pTickRate = Math.Max(2, standardBaseTickRate - speedIncrease);
                }
                if (p.SpeedBoostTimer > 0) pTickRate = Math.Max(1, pTickRate / 2);

                if (globalTickCounter % pTickRate == 0)
                {
                    p.Direction = p.NextDirection;
                    Point head = p.Body[0];
                    Point nextHead = new Point(head.X + p.Direction.X, head.Y + p.Direction.Y);

                    if (nextHead.X < 0 || nextHead.X >= GridWidth || nextHead.Y < 0 || nextHead.Y >= GridHeight)
                    {
                        p.IsAlive = false; continue;
                    }

                    if (lockDownTimer > 0)
                    {
                        if (nextHead.X == GridWidth / 2 || nextHead.Y == GridHeight / 2) { p.IsAlive = false; continue; }
                    }

                    bool crashed = false;
                    foreach (var other in players.Where(pl => pl.Type != PlayerType.None && pl.IsAlive))
                    {
                        if (other == p)
                        {
                            if (other.Body.Skip(1).Contains(nextHead)) crashed = true;
                        }
                        else
                        {
                            if (other.Body[0] == nextHead)
                            {
                                crashed = true;
                            }
                            else if (other.Body.Skip(1).Contains(nextHead))
                            {
                                if (p.DestructionTimer > 0)
                                {
                                    int hitIndex = other.Body.FindIndex(pt => pt == nextHead);
                                    if (hitIndex > 0)
                                    {
                                        int removedCount = other.Body.Count - hitIndex;
                                        other.Body.RemoveRange(hitIndex, removedCount);
                                        fxList.Add(new FloatingText { Text = $"CHOPPED -{removedCount * 5}pts!", X = nextHead.X * GridSize, Y = nextHead.Y * GridSize, Color = Color.Red, TicksLeft = 60 });
                                    }
                                }
                                else
                                {
                                    crashed = true;
                                }
                            }
                        }
                    }

                    if (crashed) { p.IsAlive = false; continue; }

                    p.Body.Insert(0, nextHead);

                    bool ateFood = false;
                    for (int i = powerUps.Count - 1; i >= 0; i--)
                    {
                        if (powerUps[i].Position == nextHead)
                        {
                            var type = powerUps[i].Type;
                            powerUps.RemoveAt(i);
                            ateFood = true;

                            string fxMsg = "+5pts"; Color fxCol = Color.Lime;

                            if (type == PowerUpType.Food)
                            {
                                SpawnPowerUp(PowerUpType.Food);
                            }
                            else if (type == PowerUpType.Speed) { p.SpeedBoostTimer = 300; fxMsg = "SPEED UP!"; fxCol = Color.Cyan; }
                            else if (type == PowerUpType.LockDown) { lockDownTimer = 1200; fxMsg = "LOCKDOWN!"; fxCol = Color.Red; }
                            else if (type == PowerUpType.ColourChanger) { ExecuteColourChanger(p); fxMsg = "COLOUR CHANGER!"; fxCol = Color.Magenta; }
                            else if (type == PowerUpType.TP) { ExecuteTP(p); fxMsg = "TELEPORT!"; fxCol = Color.Yellow; }
                            else if (type == PowerUpType.Destruction) { p.DestructionTimer = 300; fxMsg = "DESTRUCTION!"; fxCol = Color.OrangeRed; }
                            else if (type == PowerUpType.Bomb) { p.IsAlive = false; fxMsg = "BOOM! BOMB!"; fxCol = Color.Red; }

                            fxList.Add(new FloatingText { Text = fxMsg, X = head.X * GridSize, Y = (head.Y - 1) * GridSize, Color = fxCol, TicksLeft = 60 });
                        }
                    }

                    if (!ateFood) p.Body.RemoveAt(p.Body.Count - 1);
                }

                if (p.SpeedBoostTimer > 0) p.SpeedBoostTimer--;
                if (p.DestructionTimer > 0) p.DestructionTimer--;
            }

            if (lockDownTimer > 0) lockDownTimer--;

            if (globalTickCounter % 300 == 0 && powerUps.Count < 4)
            {
                var rand = new Random();
                int chance = rand.Next(100);
                if (chance < 12) SpawnPowerUp(PowerUpType.LockDown);
                else if (chance < 24) SpawnPowerUp(PowerUpType.Bomb);
                else if (chance < 38) SpawnPowerUp(PowerUpType.ColourChanger);
                else if (chance < 52) SpawnPowerUp(PowerUpType.TP);
                else if (chance < 66) SpawnPowerUp(PowerUpType.Destruction);
                else if (chance < 84) SpawnPowerUp(PowerUpType.Speed);
                else SpawnPowerUp(PowerUpType.Food);
            }

            CheckWinConditions();
        }

        private void CalculateBotMove(SnakePlayer bot)
        {
            Point head = bot.Body[0];
            Point[] directions = { new Point(0, -1), new Point(0, 1), new Point(-1, 0), new Point(1, 0) };
            List<Point> safeMoves = new List<Point>();

            foreach (var dir in directions)
            {
                if (dir.X == -bot.Direction.X && dir.Y == -bot.Direction.Y) continue;

                Point next = new Point(head.X + dir.X, head.Y + dir.Y);
                if (next.X < 0 || next.X >= GridWidth || next.Y < 0 || next.Y >= GridHeight) continue;
                if (lockDownTimer > 0 && (next.X == GridWidth / 2 || next.Y == GridHeight / 2)) continue;

                bool collision = false;
                foreach (var p in players.Where(pl => pl.Type != PlayerType.None && pl.IsAlive))
                {
                    if (p.Body.Contains(next)) collision = true;
                }
                if (!collision) safeMoves.Add(dir);
            }

            if (safeMoves.Count == 0) return;

            Point chosenMove = safeMoves[new Random().Next(safeMoves.Count)];

            if (powerUps.Count > 0)
            {
                var target = powerUps.OrderBy(pu => Math.Abs(pu.Position.X - head.X) + Math.Abs(pu.Position.Y - head.Y)).First();
                int aiThreshold = bot.Type == PlayerType.BotEasy ? 30 : (bot.Type == PlayerType.BotNormal ? 75 : 100);

                if (new Random().Next(100) < aiThreshold)
                {
                    int bestDist = int.MaxValue;
                    foreach (var move in safeMoves)
                    {
                        int dist = Math.Abs((head.X + move.X) - target.Position.X) + Math.Abs((head.Y + move.Y) - target.Position.Y);
                        if (dist < bestDist)
                        {
                            bestDist = dist;
                            chosenMove = move;
                        }
                    }
                }
            }

            bot.NextDirection = chosenMove;
        }

        private void ExecuteColourChanger(SnakePlayer p)
        {
            var active = players.Where(pl => pl.Type != PlayerType.None && pl.IsAlive && pl != p).ToList();
            if (active.Count == 0) return;
            var target = active[new Random().Next(active.Count)];

            Color tempColor = p.SnakeColor;
            p.SnakeColor = target.SnakeColor;
            target.SnakeColor = tempColor;

            int tempLen = p.Body.Count;
            int targetLen = target.Body.Count;
            
            while (p.Body.Count < targetLen) p.Body.Add(p.Body.Last());
            while (p.Body.Count > targetLen) p.Body.RemoveAt(p.Body.Count - 1);

            while (target.Body.Count < tempLen) target.Body.Add(target.Body.Last());
            while (target.Body.Count > tempLen) target.Body.RemoveAt(target.Body.Count - 1);
        }

        private void ExecuteTP(SnakePlayer p)
        {
            var active = players.Where(pl => pl.Type != PlayerType.None && pl.IsAlive && pl != p).ToList();
            if (active.Count == 0) return;
            var target = active[new Random().Next(active.Count)];

            var tempBody = new List<Point>(p.Body);
            p.Body = new List<Point>(target.Body);
            target.Body = tempBody;
            
            var tempDir = p.Direction;
            p.Direction = target.Direction;
            target.Direction = tempDir;
            
            var tempNextDir = p.NextDirection;
            p.NextDirection = target.NextDirection;
            target.NextDirection = tempNextDir;
        }

        private void SpawnPowerUp(PowerUpType type)
        {
            var rand = new Random();
            Point pt;
            while (true)
            {
                pt = new Point(rand.Next(1, GridWidth - 1), rand.Next(1, GridHeight - 1));
                if (pt.X == GridWidth / 2 || pt.Y == GridHeight / 2) continue;
                if (players.Any(p => p.Type != PlayerType.None && p.IsAlive && p.Body.Contains(pt))) continue;
                break;
            }
            powerUps.Add(new PowerUp { Position = pt, Type = type });
        }

        private void CheckWinConditions()
        {
            var activePlayers = players.Where(p => p.Type != PlayerType.None).ToList();
            var alivePlayers = players.Where(p => p.Type != PlayerType.None && p.IsAlive).ToList();

            if (currentMode == GameMode.Classic1P)
            {
                if (alivePlayers.Count == 0) EndGame("Game Over! Score: " + activePlayers[0].Score);
            }
            else if (currentMode == GameMode.Survival || currentMode == GameMode.Rush)
            {
                if (alivePlayers.Count == 1 && activePlayers.Count > 1)
                {
                    string modeName = currentMode == GameMode.Rush ? "Rush" : "Survival";
                    string winnerColor = GetColorName(alivePlayers[0].SnakeColor);
                    EndGame($"Player {alivePlayers[0].Index + 1} ({winnerColor}) Wins {modeName}!");
                    if (alivePlayers[0].Type == PlayerType.HumanKeyboard || alivePlayers[0].Type == PlayerType.HumanGamepad) config.AddWin(alivePlayers[0].Index);
                }
                else if (alivePlayers.Count == 0)
                {
                    if (currentMode == GameMode.Rush && activePlayers.Count > 0)
                    {
                        var best = activePlayers.OrderByDescending(x => x.Score).First();
                        EndGame($"Rush Over! Final Best Score: {best.Score} pts");
                    }
                    else
                    {
                        EndGame("Draw! Everyone died.");
                    }
                }
            }
            else if (currentMode == GameMode.FirstTo)
            {
                foreach (var p in activePlayers)
                {
                    if (p.Score >= targetScore)
                    {
                        string winnerColor = GetColorName(p.SnakeColor);
                        EndGame($"Player {p.Index + 1} ({winnerColor}) Reached Target Score ({targetScore})!");
                        if (p.Type == PlayerType.HumanKeyboard || p.Type == PlayerType.HumanGamepad) config.AddWin(p.Index);
                        return;
                    }
                }
                if (alivePlayers.Count == 0) EndGame("Draw! Everyone died.");
            }
        }

        private void EndGame(string msg)
        {
            gameOverMessage = msg;
            currentState = GameState.GameOver;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            float scaleX = (float)this.ClientSize.Width / (GridWidth * GridSize);
            float scaleY = (float)this.ClientSize.Height / ((GridHeight + UIHeightOffset) * GridSize);
            g.ScaleTransform(scaleX, scaleY);

            if (currentState == GameState.MainMenu) DrawMainMenu(g);
            else if (currentState == GameState.Settings) DrawSettingsMenu(g);
            else if (currentState == GameState.HowToPlay) DrawHowToPlay(g);
            else if (currentState == GameState.Lobby) DrawLobby(g);
            else DrawGame(g);
        }

        private void DrawMainMenu(Graphics g)
        {
            StringFormat center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("SNAKE EXPRESS", new Font("Impact", 48), Brushes.LimeGreen, (GridWidth * GridSize) / 2, 120, center);

            string[] options = { "Play Game", "Settings", "How To Play", "Exit" };
            for (int i = 0; i < options.Length; i++)
            {
                Brush b = menuSelectionIndex == i ? Brushes.Yellow : Brushes.White;
                string text = menuSelectionIndex == i ? $"> {options[i]} <" : options[i];
                g.DrawString(text, new Font("Arial", 22, FontStyle.Bold), b, (GridWidth * GridSize) / 2, 300 + (i * 55), center);
            }
            
            g.DrawString("W/S/Arrow Keys or D-Pad to Move | Enter/A to Select", new Font("Arial", 11), Brushes.Gray, (GridWidth * GridSize) / 2, (GridHeight * GridSize) - 40, center);
        }

        private void DrawSettingsMenu(Graphics g)
        {
            StringFormat center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("SETTINGS", new Font("Impact", 36), Brushes.Cyan, (GridWidth * GridSize) / 2, 80, center);

            string currentRes = $"{config.ResWidth}x{config.ResHeight}";
            string[] options = { $"Resolution: {currentRes}", $"Fullscreen: {(config.Fullscreen ? "ON" : "OFF")}", "Press B / Escape to Return" };
            
            for (int i = 0; i < options.Length; i++)
            {
                Brush b = i == 2 ? Brushes.Yellow : Brushes.White;
                g.DrawString(options[i], new Font("Arial", 20, FontStyle.Bold), b, (GridWidth * GridSize) / 2, 250 + (i * 60), center);
            }
        }

        private void DrawHowToPlay(Graphics g)
        {
            StringFormat center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("HOW TO PLAY", new Font("Impact", 32), Brushes.LimeGreen, (GridWidth * GridSize) / 2, 40, center);

            string instructions = 
                "CONTROLS:\n" +
                "• Keyboard Player: W, A, S, D or Arrow Keys.\n" +
                "• Controller Players: Xbox D-Pad.\n\n" +
                "GAME MODES:\n" +
                "• Survival: Last snake alive wins.\n" +
                "• First To: Reach target score first.\n" +
                "• Classic 1P: Single player survival.\n" +
                "• Rush: Speed increases with every food eaten!\n\n" +
                "POWER-UPS & ITEMS:\n" +
                "• Food (Red): +5 points, grows snake.\n" +
                "• Speed (Cyan): Temporary speed boost.\n" +
                "• LockDown (Dark Red X): Center cross barrier active.\n" +
                "• Colour Changer (Magenta): Swaps colors & lengths with rival.\n" +
                "• Teleport (Yellow): Swaps positions & bodies.\n" +
                "• Destruction (Orange): Chop rival tails on contact.\n" +
                "• Bomb (Grey B): Instant death on impact!";

            var sfLeft = new StringFormat { Alignment = StringAlignment.Near, LineAlignment = StringAlignment.Near };
            g.DrawString(instructions, new Font("Arial", 11), Brushes.White, 100, 100, sfLeft);

            g.DrawString("Press B / Escape / Enter to Return", new Font("Arial", 12, FontStyle.Bold), Brushes.Yellow, (GridWidth * GridSize) / 2, (GridHeight * GridSize) - 35, center);
        }

        private void DrawLobby(Graphics g)
        {
            StringFormat center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("GAME LOBBY SETUP", new Font("Impact", 30), Brushes.LimeGreen, (GridWidth * GridSize) / 2, 30, center);
            
            for (int i = 0; i < 4; i++)
            {
                int x = ((GridWidth * GridSize) / 5) * (i + 1);
                int y = 180;
                var p = players[i];
                var wins = config.GetWins(i);

                Brush slotBrush = lobbySelectionIndex == i ? Brushes.Yellow : Brushes.White;
                if (lobbySelectionIndex == i) g.DrawRectangle(Pens.Yellow, x - 95, y - 45, 190, 220);

                g.DrawString($"Player {i + 1}", new Font("Arial", 14, FontStyle.Bold), slotBrush, x, y, center);
                g.DrawString($"Wins: {wins}", new Font("Arial", 10), Brushes.LightGray, x, y + 25, center);

                string typeStr = "OFF";
                if (p.Type == PlayerType.HumanKeyboard) typeStr = "Human (Key)";
                else if (p.Type == PlayerType.HumanGamepad) typeStr = "Human (Pad)";
                else if (p.Type == PlayerType.BotEasy) typeStr = "Bot (Easy)";
                else if (p.Type == PlayerType.BotNormal) typeStr = "Bot (Norm)";
                else if (p.Type == PlayerType.BotHard) typeStr = "Bot (Hard)";

                g.DrawString($"< {typeStr} >", new Font("Arial", 11, FontStyle.Bold), p.Type == PlayerType.None ? Brushes.Gray : Brushes.Cyan, x, y + 65, center);

                if (p.Type != PlayerType.None)
                {
                    using (SolidBrush b = new SolidBrush(p.SnakeColor)) g.FillRectangle(b, x - 18, y + 95, 36, 36);
                    string colName = GetColorName(p.SnakeColor);
                    g.DrawString($"Color: {colName}", new Font("Arial", 9, FontStyle.Bold), Brushes.White, x, y + 140, center);
                    g.DrawString("Press A: Unique Color", new Font("Arial", 8), Brushes.LightGray, x, y + 160, center);
                }
            }

            int modeY = 440;
            Brush modeBrush = lobbySelectionIndex == 4 ? Brushes.Yellow : Brushes.White;
            g.DrawString($"Game Mode: < {currentMode} >", new Font("Arial", 16, FontStyle.Bold), modeBrush, (GridWidth * GridSize) / 2, modeY, center);

            if (currentMode == GameMode.FirstTo)
            {
                Brush scoreBrush = lobbySelectionIndex == 5 ? Brushes.Yellow : Brushes.White;
                g.DrawString($"Target Score: < {targetScore} >", new Font("Arial", 16, FontStyle.Bold), scoreBrush, (GridWidth * GridSize) / 2, modeY + 45, center);
            }

            g.DrawString("D-PAD / Arrow Keys: Navigate | A: Unique Color | START: Play | B: Back", new Font("Arial", 11, FontStyle.Bold), Brushes.Yellow, (GridWidth * GridSize) / 2, (GridHeight * GridSize) - 25, center);
        }

        private void DrawGame(Graphics g)
        {
            g.FillRectangle(Brushes.Black, 0, 0, GridWidth * GridSize, UIHeightOffset * GridSize);
            g.DrawLine(Pens.Gray, 0, UIHeightOffset * GridSize, GridWidth * GridSize, UIHeightOffset * GridSize);

            int xSection = (GridWidth * GridSize) / 4;
            for (int i = 0; i < 4; i++)
            {
                var p = players[i];
                if (p.Type == PlayerType.None) continue;
                Brush textBrush = p.IsAlive ? Brushes.White : Brushes.DimGray;
                string colName = GetColorName(p.SnakeColor);
                string label = "";
                if (p.Type == PlayerType.HumanKeyboard || p.Type == PlayerType.HumanGamepad) label = $"P{i+1} ({colName})";
                else label = $"Bot ({colName})";

                string statusExtra = "";
                if (p.DestructionTimer > 0) statusExtra = " [DESTRUCT]";
                g.DrawString($"{label}: {p.Score}{statusExtra}", new Font("Consolas", 10, FontStyle.Bold), textBrush, (xSection * i) + 5, 10);
            }

            g.TranslateTransform(0, UIHeightOffset * GridSize);
            g.DrawRectangle(Pens.DarkSlateGray, 0, 0, GridWidth * GridSize, GridHeight * GridSize);

            if (lockDownTimer > 0)
            {
                int midX = (GridWidth / 2) * GridSize;
                int midY = (GridHeight / 2) * GridSize;
                using (var pen = new Pen(Color.Red, 4))
                {
                    g.DrawLine(pen, midX, 0, midX, GridHeight * GridSize);
                    g.DrawLine(pen, 0, midY, GridWidth * GridSize, midY);
                }
                g.DrawString("LOCKDOWN", new Font("Arial", 14, FontStyle.Bold), Brushes.Red, 10, 10);
            }

            foreach (var p in powerUps)
            {
                Rectangle rect = new Rectangle(p.Position.X * GridSize, p.Position.Y * GridSize, GridSize, GridSize);
                if (p.Type == PowerUpType.Food) g.FillEllipse(Brushes.Red, rect);
                else if (p.Type == PowerUpType.Speed) g.FillRectangle(Brushes.Cyan, rect);
                else if (p.Type == PowerUpType.LockDown) { g.FillRectangle(Brushes.DarkRed, rect); g.DrawString("X", new Font("Arial", 12), Brushes.White, rect.X+2, rect.Y+2); }
                else if (p.Type == PowerUpType.ColourChanger) g.FillRectangle(Brushes.Magenta, rect);
                else if (p.Type == PowerUpType.TP) g.FillRectangle(Brushes.Yellow, rect);
                else if (p.Type == PowerUpType.Destruction) g.FillRectangle(Brushes.OrangeRed, rect);
                else if (p.Type == PowerUpType.Bomb) { g.FillEllipse(Brushes.DimGray, rect); g.DrawString("B", new Font("Arial", 9, FontStyle.Bold), Brushes.Red, rect.X+5, rect.Y+5); }
            }

            foreach (var p in players.Where(pl => pl.Type != PlayerType.None))
            {
                if (p.Body.Count == 0) continue;
                using (SolidBrush brush = new SolidBrush(p.IsAlive ? p.SnakeColor : Color.FromArgb(50, p.SnakeColor)))
                {
                    foreach (var pt in p.Body) g.FillRectangle(brush, pt.X * GridSize, pt.Y * GridSize, GridSize - 1, GridSize - 1);
                    if (p.SpeedBoostTimer > 0 && p.IsAlive)
                        g.DrawRectangle(Pens.Cyan, p.Body[0].X * GridSize, p.Body[0].Y * GridSize, GridSize, GridSize);
                    if (p.DestructionTimer > 0 && p.IsAlive)
                        g.DrawRectangle(Pens.OrangeRed, p.Body[0].X * GridSize, p.Body[0].Y * GridSize, GridSize, GridSize);
                }
            }

            for (int i = fxList.Count - 1; i >= 0; i--)
            {
                var fx = fxList[i];
                using (SolidBrush b = new SolidBrush(Color.FromArgb((int)((fx.TicksLeft / 60.0f) * 255), fx.Color)))
                {
                    g.DrawString(fx.Text, new Font("Impact", 12), b, fx.X, fx.Y);
                }
                fx.Y -= 0.8f;
                fx.TicksLeft--;
                if (fx.TicksLeft <= 0) fxList.RemoveAt(i);
            }

            if (currentState == GameState.GameOver)
            {
                StringFormat center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.FillRectangle(new SolidBrush(Color.FromArgb(180, 0, 0, 0)), 0, 0, GridWidth * GridSize, GridHeight * GridSize);
                g.DrawString(gameOverMessage, new Font("Impact", 28), Brushes.White, (GridWidth * GridSize) / 2, (GridHeight * GridSize) / 2 - 40, center);
                g.DrawString("Press B / Enter to return to Lobby", new Font("Arial", 14), Brushes.Yellow, (GridWidth * GridSize) / 2, (GridHeight * GridSize) / 2 + 20, center);
            }
        }
    }
}
'@

# 4. Build, Log, and Run
Write-Host "Building and publishing executable..." -ForegroundColor Magenta

$publishDir = Join-Path $targetRoot "Publish"
$buildArgs = "publish `"$targetRoot`" -c $Configuration -o `"$publishDir`" --nologo"
Write-Host "Executing: dotnet $buildArgs > $logFile" -ForegroundColor DarkGray

cmd.exe /c "dotnet $buildArgs > `"$logFile`" 2>&1"

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nBuild Successful! Build.log has been written to the project directory." -ForegroundColor Green
    
    $exePath = Join-Path $publishDir "SnakeExpress.exe"
    
    if (Test-Path $exePath) {
        Write-Host "Launching Game: $exePath" -ForegroundColor Cyan
        Start-Process $exePath
    } else {
        Write-Host "ERROR: Compiled Executable not found in publish directory. Check Build.log for details." -ForegroundColor Red
    }
} else {
    Write-Host "ERROR: Build Failed. Please review the Build.log file located at:" -ForegroundColor Red
    Write-Host "-> $logFile" -ForegroundColor Yellow
}