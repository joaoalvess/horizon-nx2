using Ryujinx.Graphics.Shader.Instructions;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation.Optimizations;
using System.Collections.Generic;
using System.Diagnostics;

using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

namespace Ryujinx.Graphics.Shader.Translation.Transforms
{
    // nxnative: MatrixMultiplyAdd (Ampere HMMA.16816 with an f16 accumulator, InstEmitAmpereTensor.AHmma) becomes a call of the helper dmsh_hmma16816_f16, or of its variant
    // dmsh_hmma16816_f16_<layouts> when some of its words are in the layout of Apple's simdgroup_matrix, whose body the shader build replaces with simdgroup_matrix code in the
    // Metal source. Sources: the scratch shared memory id (constant), the lane, the subgroup's block offset, A (4), B (2), C (2); destinations: D (2), the first as the call's
    // result, the second through its out argument (as ShufflePass does with its valid flag). MatrixLoad (an LDSM matrix, InstEmitAmpereTensor.ALdsm) becomes its shared memory loads
    class TensorPass : ITransformPass
    {
        private const int KindA = 1;
        private const int KindB = 2;
        private const int KindC = 3;

        public static bool IsEnabled(IGpuAccessor gpuAccessor, ShaderStage stage, TargetLanguage targetLanguage, FeatureFlags usedFeatures)
        {
            return true;
        }

        public static LinkedListNode<INode> RunPass(TransformContext context, LinkedListNode<INode> node)
        {
            Operation operation = (Operation)node.Value;

            if (operation.Inst == Instruction.MatrixLoad)
            {
                if (operation.SourcesCount == 6)
                {
                    ChooseLayouts(context.Blocks);
                }

                return LowerMatrixLoad(node, operation);
            }

            if (operation.Inst != Instruction.MatrixMultiplyAdd)
            {
                return node;
            }

            if (operation.SourcesCount == 11)
            {
                ChooseLayouts(context.Blocks);
            }

            Operand memoryId = operation.GetSource(0);

            Debug.Assert(memoryId.Type == OperandType.Constant && memoryId.Value < 64);

            int functionId = context.Hfm.GetOrCreateFunctionId(HelperFunctionName.Hmma16816F16, memoryId.Value | (operation.GetSource(11).Value << 6));

            Operand d0 = operation.GetDest(0);
            Operand d1 = operation.GetDest(1);

            operation.Dest = null;

            Operand[] callArgs = new Operand[12];
            callArgs[0] = Const(functionId);

            for (int i = 0; i < 10; i++)
            {
                callArgs[1 + i] = operation.GetSource(1 + i);
            }

            callArgs[11] = d1;

            LinkedListNode<INode> newNode = node.List.AddBefore(node, new Operation(Instruction.Call, 0, d0, callArgs));

            Utils.DeleteNode(node, operation);

            return newNode;
        }

        public static Operand AppleRow(EmitterContext context, Operand lane)
        {
            return context.BitwiseOr(context.ShiftLeft(context.ShiftRightU32(lane, Const(4)), Const(2)), context.BitwiseAnd(context.ShiftRightU32(lane, Const(1)), Const(3)));
        }

        public static Operand ApplePair(EmitterContext context, Operand lane)
        {
            return context.BitwiseOr(context.BitwiseAnd(context.ShiftRightU32(lane, Const(2)), Const(2)), context.BitwiseAnd(lane, Const(1)));
        }

        public static Operand AppleLane(EmitterContext context, Operand row, Operand pair)
        {
            Operand high = context.BitwiseOr(context.ShiftLeft(context.ShiftRightU32(row, Const(2)), Const(4)), context.ShiftLeft(context.ShiftRightU32(pair, Const(1)), Const(3)));

            return context.BitwiseOr(high, context.BitwiseOr(context.ShiftLeft(context.BitwiseAnd(row, Const(3)), Const(1)), context.BitwiseAnd(pair, Const(1))));
        }

        private static LinkedListNode<INode> LowerMatrixLoad(LinkedListNode<INode> node, Operation operation)
        {
            int id = operation.GetSource(0).Value;
            int scratch = operation.GetSource(1).Value;
            bool transposed = operation.GetSource(2).Value != 0;
            int m = operation.GetSource(3).Value;
            Operand lane = operation.GetSource(4);
            Operand block = operation.GetSource(5);
            int kind = operation.GetSource(6).Value;
            Operand dest = operation.Dest;

            operation.Dest = null;

            EmitterContext context = new();
            Operand major = kind == 0 ? context.ShiftRightU32(lane, Const(2)) : AppleRow(context, lane);
            Operand minor = kind == 0 ? context.BitwiseAnd(lane, Const(3)) : ApplePair(context, lane);
            Operand value = InstEmit.ALdsmMatrix(context, id, m, transposed != (kind == KindB), major, minor, row => context.Load(StorageKind.SharedMemory, scratch, context.IAdd(block, row)));

            context.Copy(dest, value);

            LinkedListNode<INode> last = node;

            foreach (Operation lowered in context.GetOperations())
            {
                last = node.List.AddBefore(node, lowered);
            }

            Utils.DeleteNode(node, operation);

            return last;
        }

        private static int SlotKind(int source)
        {
            return source < 3 ? 0 : source < 7 ? KindA : source < 9 ? KindB : KindC;
        }

        private static bool Fits(Operand constant, int kind)
        {
            return kind != KindB || ((constant.Value ^ (constant.Value >> 16)) & 0xffff) == 0;
        }

        private static bool Agree(ref int kind, int other)
        {
            if (other == 0)
            {
                return false;
            }

            if (kind < 0)
            {
                kind = other;
            }

            return other < 0 || kind == other;
        }

        private static void ChooseLayouts(BasicBlock[] blocks)
        {
            Dictionary<Operand, int> kinds = [];
            List<Operation> matrixOps = [];

            foreach (BasicBlock block in blocks)
            {
                foreach (INode node in block.Operations)
                {
                    if (node is PhiNode phi)
                    {
                        kinds[phi.Dest] = -1;
                    }
                    else if (node is Operation operation && operation.Inst is Instruction.MatrixLoad or Instruction.MatrixMultiplyAdd)
                    {
                        matrixOps.Add(operation);

                        for (int i = 0; i < operation.DestsCount; i++)
                        {
                            kinds[operation.GetDest(i)] = operation.Inst == Instruction.MatrixLoad ? -1 : KindC;
                        }
                    }
                }
            }

            List<Operand> values = [.. kinds.Keys];

            for (bool changed = true; changed;)
            {
                changed = false;

                foreach (Operand value in values)
                {
                    int kind = kinds[value];
                    int settled = kind == 0 ? 0 : Settle(value, kind, kinds);

                    if (settled != kind)
                    {
                        kinds[value] = settled;
                        changed = true;
                    }
                }
            }

            foreach (Operation operation in matrixOps)
            {
                if (operation.Inst == Instruction.MatrixLoad)
                {
                    int kind = kinds[operation.Dest];

                    operation.AppendSources([Const((kind is KindA or KindB) ? kind : 0)]);

                    continue;
                }

                int layouts = 0;

                for (int i = 3; i < 11; i++)
                {
                    Operand source = operation.GetSource(i);
                    bool apple = source.Type == OperandType.Constant ? Fits(source, SlotKind(i)) : kinds.TryGetValue(source, out int kind) && kind == SlotKind(i);

                    layouts |= apple ? 1 << (i - 3) : 0;
                }

                for (int i = 0; i < 2; i++)
                {
                    layouts |= kinds[operation.GetDest(i)] == KindC ? 1 << (8 + i) : 0;
                }

                operation.AppendSources([Const(layouts)]);
            }
        }

        private static int Settle(Operand value, int kind, Dictionary<Operand, int> kinds)
        {
            foreach (INode use in value.UseOps)
            {
                if (use is Operation { Inst: Instruction.MatrixMultiplyAdd } operation)
                {
                    for (int i = 0; i < operation.SourcesCount; i++)
                    {
                        if (operation.GetSource(i) == value && !Agree(ref kind, SlotKind(i)))
                        {
                            return 0;
                        }
                    }
                }
                else if (use is not PhiNode phi || !kinds.TryGetValue(phi.Dest, out int phiKind) || !Agree(ref kind, phiKind))
                {
                    return 0;
                }
            }

            if (value.AsgOp is PhiNode def)
            {
                for (int i = 0; i < def.SourcesCount; i++)
                {
                    Operand source = def.GetSource(i);

                    if (source.Type == OperandType.Constant ? !Fits(source, kind) : !kinds.TryGetValue(source, out int sourceKind) || !Agree(ref kind, sourceKind))
                    {
                        return 0;
                    }
                }
            }
            else if (value.AsgOp is Operation { Inst: Instruction.MatrixLoad } && kind == KindC)
            {
                return 0;
            }

            return kind;
        }
    }
}
